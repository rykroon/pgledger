package main

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"sort"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

const (
	codeReserve = 1
	codeHot     = 2
	codeNormal  = 3
	codeFunding = 1
	codeRun     = 2
)

type ledgerSet struct {
	id      uuid.UUID
	all     []uuid.UUID // hot accounts first, then normal
	hot     []uuid.UUID
	normal  []uuid.UUID
	reserve uuid.UUID // zero unless -rules
}

type world struct {
	runID   uuid.UUID
	ledgers []*ledgerSet
	cum     []float64 // cumulative zipf weights over ledgers, for -ledger-skew
}

type transfer struct {
	id, ledger, debit, credit uuid.UUID
	amount                    int64
	code                      int32
}

func newID(version string) uuid.UUID {
	if version == "v4" {
		return uuid.New()
	}
	id, err := uuid.NewV7()
	if err != nil {
		panic(err)
	}
	return id
}

// gen produces one client's transfers from its own seeded source, so a run is reproducible for
// a given -seed regardless of scheduling.
type gen struct {
	r   *rand.Rand
	cfg *config
	w   *world
}

func (g *gen) pickLedger() *ledgerSet {
	ls := g.w.ledgers
	if len(ls) == 1 {
		return ls[0]
	}
	if g.cfg.ledgerSkew == 0 {
		return ls[g.r.Intn(len(ls))]
	}
	x := g.r.Float64() * g.w.cum[len(g.w.cum)-1]
	i := sort.SearchFloat64s(g.w.cum, x)
	if i >= len(ls) {
		i = len(ls) - 1
	}
	return ls[i]
}

func (g *gen) next() transfer {
	l := g.pickLedger()
	var a, b uuid.UUID
	if len(l.hot) > 0 && g.r.Float64() < g.cfg.hotRatio {
		a = l.hot[g.r.Intn(len(l.hot))]
		b = l.normal[g.r.Intn(len(l.normal))]
	} else {
		n := len(l.all)
		i := g.r.Intn(n)
		j := g.r.Intn(n - 1)
		if j >= i {
			j++
		}
		a, b = l.all[i], l.all[j]
	}
	if g.r.Intn(2) == 0 {
		a, b = b, a
	}
	return transfer{
		id:     newID(g.cfg.uuidVersion),
		ledger: l.id,
		debit:  a,
		credit: b,
		amount: 1 + g.r.Int63n(g.cfg.amountMax),
		code:   codeRun,
	}
}

// One prepared statement whatever the batch size; pgx caches it per connection. Posting
// goes through create_transfers(), which returns a result per row instead of failing the
// statement; the composite array is built server-side so the client keeps its parallel-array
// bind parameters, and the result is folded to a count of rejected rows.
func insertSQL(schema string) string {
	q := pgx.Identifier{schema}.Sanitize()
	return fmt.Sprintf(`SELECT count(*) FILTER (WHERE code <> 'ok')
FROM %s.create_transfers(ARRAY(
    SELECT ROW(t.id, t.ledger, t.debit, t.credit, t.amount, t.code, t.ext, NULL)::%s.transfer_input
    FROM unnest($1::uuid[], $2::uuid[], $3::uuid[], $4::uuid[], $5::numeric[], $6::int[], $7::uuid[])
         AS t(id, ledger, debit, credit, amount, code, ext)
))`, q, q)
}

func postBatch(ctx context.Context, conn *pgx.Conn, sql string, batch []transfer, runID uuid.UUID) (int64, error) {
	n := len(batch)
	ids := make([]uuid.UUID, n)
	ledgers := make([]uuid.UUID, n)
	debits := make([]uuid.UUID, n)
	credits := make([]uuid.UUID, n)
	amounts := make([]int64, n)
	codes := make([]int32, n)
	ext := make([]uuid.UUID, n)
	for i, t := range batch {
		ids[i], ledgers[i], debits[i], credits[i] = t.id, t.ledger, t.debit, t.credit
		amounts[i], codes[i], ext[i] = t.amount, t.code, runID
	}
	var rejected int64
	err := conn.QueryRow(ctx, sql, ids, ledgers, debits, credits, amounts, codes, ext).Scan(&rejected)
	return rejected, err
}

type phaseResult struct {
	wall       time.Duration
	statements int
	failed     int
	attempted  int64
	posted     int64
	lat        []time.Duration
	errs       map[string]int
	samples    map[string]string
}

func sqlstate(err error) string {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return pgErr.Code
	}
	return "client"
}

// runPhase posts n transfers split evenly across the client connections, each statement its
// own transaction. A batch is no longer all-or-nothing: create_transfers() rejects rows
// individually, counted under the pseudo-code "rejected". Whole-statement failures are still
// counted by SQLSTATE and never retried.
func runPhase(ctx context.Context, cfg *config, conns []*pgx.Conn, w *world, n int, seed int64) phaseResult {
	sql := insertSQL(cfg.schema)
	results := make([]phaseResult, len(conns))
	start := make(chan struct{})
	var ready, done sync.WaitGroup

	base, rem := n/len(conns), n%len(conns)
	for i, conn := range conns {
		quota := base
		if i < rem {
			quota++
		}
		ready.Add(1)
		done.Add(1)
		go func(i int, conn *pgx.Conn, quota int) {
			defer done.Done()
			g := &gen{r: rand.New(rand.NewSource(seed*1000003 + int64(i))), cfg: cfg, w: w}
			res := phaseResult{errs: map[string]int{}, samples: map[string]string{}}
			batch := make([]transfer, 0, cfg.batch)
			ready.Done()
			<-start
			for remaining := quota; remaining > 0 && ctx.Err() == nil; {
				k := min(cfg.batch, remaining)
				batch = batch[:0]
				for j := 0; j < k; j++ {
					batch = append(batch, g.next())
				}
				t0 := time.Now()
				rejected, err := postBatch(ctx, conn, sql, batch, w.runID)
				res.lat = append(res.lat, time.Since(t0))
				res.statements++
				res.attempted += int64(k)
				remaining -= k
				if err == nil {
					res.posted += int64(k) - rejected
					if rejected > 0 {
						res.errs["rejected"] += int(rejected)
					}
					continue
				}
				res.failed++
				code := sqlstate(err)
				res.errs[code]++
				if _, seen := res.samples[code]; !seen {
					res.samples[code] = err.Error()
				}
				if code == "client" {
					break // connection-level failure; don't spin
				}
			}
			// Push this backend's pg_stat_database counters out so the report's deltas are current.
			_, _ = conn.Exec(context.Background(), "SELECT pg_stat_force_next_flush()")
			results[i] = res
		}(i, conn, quota)
	}

	ready.Wait()
	t0 := time.Now()
	close(start)
	done.Wait()
	wall := time.Since(t0)

	merged := phaseResult{wall: wall, errs: map[string]int{}, samples: map[string]string{}}
	for _, r := range results {
		merged.statements += r.statements
		merged.failed += r.failed
		merged.attempted += r.attempted
		merged.posted += r.posted
		merged.lat = append(merged.lat, r.lat...)
		for k, v := range r.errs {
			merged.errs[k] += v
			if _, ok := merged.samples[k]; !ok {
				merged.samples[k] = r.samples[k]
			}
		}
	}
	sort.Slice(merged.lat, func(i, j int) bool { return merged.lat[i] < merged.lat[j] })
	return merged
}
