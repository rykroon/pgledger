package main

import (
	"context"
	"fmt"
	"math"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

const accountChunk = 1000

type accountRow struct {
	id           uuid.UUID
	ledger       int32
	code         int32
	requireDebit bool
}

// parallel runs fn on n goroutines and returns the first error, cancelling the rest.
func parallel(ctx context.Context, n int, fn func(ctx context.Context, i int) error) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	errs := make(chan error, n)
	for i := 0; i < n; i++ {
		go func(i int) { errs <- fn(ctx, i) }(i)
	}
	var first error
	for i := 0; i < n; i++ {
		if err := <-errs; err != nil && first == nil {
			first = err
			cancel()
		}
	}
	return first
}

// setupWorld creates the accounts for this run and, with -rules, funds every
// account from its ledger's reserve so the timed run starts from a solvent ledger.
func setupWorld(ctx context.Context, cfg *config, conns []*pgx.Conn, runID uuid.UUID, rep *report) (*world, error) {
	w := &world{runID: runID}
	t0 := time.Now()

	// Ledgers 1..N, with zipf weights 1/(rank+1)^skew for -ledger-skew. A ledger is just a
	// number; there is nothing to create.
	var total float64
	for i := 0; i < cfg.ledgers; i++ {
		w.ledgers = append(w.ledgers, &ledgerSet{id: int32(i + 1)})
		total += 1 / math.Pow(float64(i+1), cfg.ledgerSkew)
		w.cum = append(w.cum, total)
	}

	// Accounts: per ledger, hot accounts first, then normal, plus a reserve when -rules.
	var rows []accountRow
	base, rem := cfg.accounts/cfg.ledgers, cfg.accounts%cfg.ledgers
	for i, l := range w.ledgers {
		n := base
		if i < rem {
			n++
		}
		for j := 0; j < n; j++ {
			id := newID(cfg.uuidVersion)
			code := int32(codeNormal)
			if j < cfg.hotAccounts {
				code = codeHot
			}
			l.all = append(l.all, id)
			rows = append(rows, accountRow{id: id, ledger: l.id, code: code, requireDebit: cfg.rules})
		}
		l.hot, l.normal = l.all[:cfg.hotAccounts], l.all[cfg.hotAccounts:]
		if cfg.rules {
			l.reserve = newID(cfg.uuidVersion)
			rows = append(rows, accountRow{id: l.reserve, ledger: l.id, code: codeReserve})
		}
	}

	chunks := make(chan []accountRow, len(rows)/accountChunk+1)
	for i := 0; i < len(rows); i += accountChunk {
		chunks <- rows[i:min(i+accountChunk, len(rows))]
	}
	close(chunks)
	// Same shape as insertSQL: built server-side, folded to a count of rejected rows.
	q := pgx.Identifier{cfg.schema}.Sanitize()
	accountSQL := fmt.Sprintf(`SELECT count(*) FILTER (WHERE code <> 'ok')
FROM %s.create_accounts(ARRAY(
    SELECT ROW(a.id, a.ledger, a.code, a.ext, NULL, false, a.require_debit, NULL)::%s.accounts
    FROM unnest($1::uuid[], $2::int[], $3::int[], $4::uuid[], $5::bool[])
         AS a(id, ledger, code, ext, require_debit)
))`, q, q)
	err := parallel(ctx, len(conns), func(ctx context.Context, i int) error {
		for chunk := range chunks {
			n := len(chunk)
			ids, ext := make([]uuid.UUID, n), make([]uuid.UUID, n)
			ledgers, codes, rules := make([]int32, n), make([]int32, n), make([]bool, n)
			for k, r := range chunk {
				ids[k], ledgers[k], codes[k], ext[k], rules[k] = r.id, r.ledger, r.code, runID, r.requireDebit
			}
			var rejected int64
			if err := conns[i].QueryRow(ctx, accountSQL, ids, ledgers, codes, ext, rules).Scan(&rejected); err != nil {
				return fmt.Errorf("create accounts: %w", err)
			}
			if rejected > 0 {
				return fmt.Errorf("create accounts: %d rows rejected", rejected)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	rep.Setup.Ledgers = cfg.ledgers
	rep.Setup.Accounts = len(rows)
	rep.Setup.Seconds = time.Since(t0).Seconds()
	rep.Setup.AccountsPerSec = float64(len(rows)) / rep.Setup.Seconds

	if !cfg.rules {
		return w, nil
	}

	// Funding: reserve -> every account. Each batch touches one reserve, so batches of one
	// ledger serialize on it while different ledgers proceed in parallel.
	t1 := time.Now()
	sql := insertSQL(cfg.schema)
	jobs := make(chan []transfer, len(rows)/accountChunk+cfg.ledgers)
	var funded int64
	for _, l := range w.ledgers {
		for i := 0; i < len(l.all); i += accountChunk {
			var batch []transfer
			for _, acct := range l.all[i:min(i+accountChunk, len(l.all))] {
				batch = append(batch, transfer{id: newID(cfg.uuidVersion), ledger: l.id, debit: acct, credit: l.reserve, amount: cfg.fund, code: codeFunding})
			}
			funded += int64(len(batch))
			jobs <- batch
		}
	}
	close(jobs)
	err = parallel(ctx, len(conns), func(ctx context.Context, i int) error {
		for batch := range jobs {
			rejected, err := postBatch(ctx, conns[i], sql, batch, runID)
			if err != nil {
				return fmt.Errorf("fund accounts: %w", err)
			}
			if rejected > 0 {
				return fmt.Errorf("fund accounts: %d rows rejected", rejected)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	rep.Setup.FundingTransfers = funded
	rep.Setup.FundingSeconds = time.Since(t1).Seconds()
	rep.postedTotal += funded
	return w, nil
}
