// Command bench measures pgledger write throughput (transfers per second) by driving
// create_transfers() from many concurrent Postgres clients.
//
// Usually run through run.sh, which starts a throwaway Postgres container first.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"math/rand/v2"
	"os"
	"os/signal"
	"slices"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
)

type config struct {
	clients     int
	batch       int
	hotRatio    float64
	transfers   int
	accounts    int
	hotAccounts int
	dsn         string
	reset       bool
	seed        uint64
	progress    time.Duration
	verify      bool
}

// Builds transfer_input[] server-side from parallel arrays so pgx doesn't need the
// composite type registered.
const createTransfersSQL = `
SELECT count(*) FROM ledger.create_transfers(ARRAY(
    SELECT ROW(NULL, u.d, u.c, u.a, 1, false, false, NULL, NULL)::ledger.transfer_input
    FROM unnest($1::uuid[], $2::uuid[], $3::bigint[]) WITH ORDINALITY u(d, c, a, n)
    ORDER BY u.n))`

func main() {
	cfg := parseFlags()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	if err := run(ctx, cfg); err != nil {
		fmt.Fprintln(os.Stderr, "bench:", err)
		os.Exit(1)
	}
}

func parseFlags() config {
	var cfg config
	defaultDSN := os.Getenv("DATABASE_URL")
	if defaultDSN == "" {
		defaultDSN = "postgres://postgres:postgres@localhost:54329/postgres"
	}
	flag.IntVar(&cfg.clients, "clients", 16, "concurrent Postgres clients creating transfers")
	flag.IntVar(&cfg.batch, "batch", 100, "transfers per create_transfers() call")
	flag.Float64Var(&cfg.hotRatio, "hot-ratio", 0, "fraction (0-1) of transfers that touch a hot account; 0 is uniform random")
	flag.IntVar(&cfg.transfers, "transfers", 100_000, "total transfers to create")
	flag.IntVar(&cfg.accounts, "accounts", 10_000, "accounts created during setup")
	flag.IntVar(&cfg.hotAccounts, "hot-accounts", 1, "number of hot accounts")
	flag.StringVar(&cfg.dsn, "dsn", defaultDSN, "Postgres connection string (default $DATABASE_URL)")
	flag.BoolVar(&cfg.reset, "reset", true, "drop and recreate the ledger schema and extension before running")
	flag.Uint64Var(&cfg.seed, "seed", 0, "RNG seed; 0 picks one from the clock")
	flag.DurationVar(&cfg.progress, "progress", time.Second, "progress report interval; 0 disables")
	flag.BoolVar(&cfg.verify, "verify", true, "after the run, check the transfer count and that every account balance matches its transfers")
	flag.Parse()

	fail := func(msg string) {
		fmt.Fprintln(os.Stderr, "bench:", msg)
		os.Exit(2)
	}
	switch {
	case cfg.clients < 1:
		fail("-clients must be >= 1")
	case cfg.batch < 1:
		fail("-batch must be >= 1")
	case cfg.hotRatio < 0 || cfg.hotRatio > 1:
		fail("-hot-ratio must be between 0 and 1")
	case cfg.transfers < 1:
		fail("-transfers must be >= 1")
	case cfg.hotAccounts < 1:
		fail("-hot-accounts must be >= 1")
	case cfg.accounts-cfg.hotAccounts < 2:
		fail("-accounts must leave at least 2 cold accounts after -hot-accounts")
	}
	if cfg.seed == 0 {
		cfg.seed = uint64(time.Now().UnixNano())
	}
	return cfg
}

func run(ctx context.Context, cfg config) error {
	poolCfg, err := pgxpool.ParseConfig(cfg.dsn)
	if err != nil {
		return err
	}
	poolCfg.MaxConns = int32(cfg.clients + 1)
	pool, err := pgxpool.NewWithConfig(ctx, poolCfg)
	if err != nil {
		return err
	}
	defer pool.Close()

	if cfg.reset {
		if _, err := pool.Exec(ctx, `
			DROP SCHEMA IF EXISTS ledger CASCADE;
			DROP EXTENSION IF EXISTS pgledger CASCADE;
			CREATE SCHEMA ledger;
			CREATE EXTENSION pgledger SCHEMA ledger;`); err != nil {
			return fmt.Errorf("reset: %w", err)
		}
	}

	ids, err := createAccounts(ctx, pool, cfg.accounts)
	if err != nil {
		return fmt.Errorf("create accounts: %w", err)
	}
	hot, cold := ids[:cfg.hotAccounts], ids[cfg.hotAccounts:]

	fmt.Printf("clients=%d batch=%d hot-ratio=%.2f hot-accounts=%d accounts=%d transfers=%d seed=%d\n",
		cfg.clients, cfg.batch, cfg.hotRatio, cfg.hotAccounts, cfg.accounts, cfg.transfers, cfg.seed)

	// remaining is handed out batch by batch; done counts committed transfers.
	var remaining, done, retries atomic.Int64
	remaining.Store(int64(cfg.transfers))

	latencies := make([][]time.Duration, cfg.clients)
	errs := make(chan error, cfg.clients)
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	start := time.Now()
	stopProgress := startProgress(cfg.progress, start, &done)

	var wg sync.WaitGroup
	for w := range cfg.clients {
		wg.Add(1)
		go func() {
			defer wg.Done()
			rng := rand.New(rand.NewPCG(cfg.seed, uint64(w)))
			lat, err := worker(ctx, pool, cfg, rng, hot, cold, &remaining, &done, &retries)
			latencies[w] = lat
			if err != nil {
				errs <- err
				cancel()
			}
		}()
	}
	wg.Wait()
	elapsed := time.Since(start)
	stopProgress()
	close(errs)
	if err := <-errs; err != nil {
		return err
	}

	report(elapsed, done.Load(), retries.Load(), slices.Concat(latencies...))

	if cfg.verify {
		return verify(context.Background(), pool, cfg)
	}
	return nil
}

func createAccounts(ctx context.Context, pool *pgxpool.Pool, n int) ([]pgtype.UUID, error) {
	rows, err := pool.Query(ctx, `
		SELECT id FROM ledger.create_accounts(ARRAY(
			SELECT ROW(NULL, 1, 100, false, false, NULL, NULL)::ledger.account_input
			FROM generate_series(1, $1)))`, n)
	if err != nil {
		return nil, err
	}
	ids := make([]pgtype.UUID, 0, n)
	for rows.Next() {
		var id pgtype.UUID
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

func worker(
	ctx context.Context, pool *pgxpool.Pool, cfg config, rng *rand.Rand,
	hot, cold []pgtype.UUID, remaining, done, retries *atomic.Int64,
) ([]time.Duration, error) {
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return nil, err
	}
	defer conn.Release()

	var lat []time.Duration
	debits := make([]pgtype.UUID, 0, cfg.batch)
	credits := make([]pgtype.UUID, 0, cfg.batch)
	amounts := make([]int64, 0, cfg.batch)

	for {
		n := int(min(remaining.Add(-int64(cfg.batch))+int64(cfg.batch), int64(cfg.batch)))
		if n <= 0 {
			return lat, nil
		}

		debits, credits, amounts = debits[:0], credits[:0], amounts[:0]
		for range n {
			d, c := pickPair(rng, cfg.hotRatio, hot, cold)
			debits = append(debits, d)
			credits = append(credits, c)
			amounts = append(amounts, rng.Int64N(1000)+1)
		}

		for {
			t0 := time.Now()
			var count int64
			err := conn.QueryRow(ctx, createTransfersSQL, debits, credits, amounts).Scan(&count)
			if err == nil {
				lat = append(lat, time.Since(t0))
				done.Add(count)
				break
			}
			var pgErr *pgconn.PgError
			if errors.As(err, &pgErr) && (pgErr.Code == "40P01" || pgErr.Code == "40001") {
				retries.Add(1)
				continue
			}
			if ctx.Err() != nil {
				return lat, nil // another worker failed or we were interrupted
			}
			return lat, fmt.Errorf("create_transfers: %w", err)
		}
	}
}

// pickPair returns a (debit, credit) pair. With probability hotRatio one side is a hot
// account and the other a cold one; otherwise both are distinct cold accounts.
func pickPair(rng *rand.Rand, hotRatio float64, hot, cold []pgtype.UUID) (pgtype.UUID, pgtype.UUID) {
	if hotRatio > 0 && rng.Float64() < hotRatio {
		h, c := hot[rng.IntN(len(hot))], cold[rng.IntN(len(cold))]
		if rng.IntN(2) == 0 {
			return h, c
		}
		return c, h
	}
	i := rng.IntN(len(cold))
	j := rng.IntN(len(cold) - 1)
	if j >= i {
		j++
	}
	return cold[i], cold[j]
}

func startProgress(every time.Duration, start time.Time, done *atomic.Int64) (stop func()) {
	if every <= 0 {
		return func() {}
	}
	quit := make(chan struct{})
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		ticker := time.NewTicker(every)
		defer ticker.Stop()
		var last int64
		lastAt := start
		for {
			select {
			case <-quit:
				return
			case now := <-ticker.C:
				cur := done.Load()
				fmt.Printf("  %6.1fs  %10d transfers  %9.0f/s interval  %9.0f/s overall\n",
					now.Sub(start).Seconds(), cur,
					float64(cur-last)/now.Sub(lastAt).Seconds(),
					float64(cur)/now.Sub(start).Seconds())
				last, lastAt = cur, now
			}
		}
	}()
	return func() { close(quit); <-finished }
}

func report(elapsed time.Duration, transfers, retries int64, lat []time.Duration) {
	slices.Sort(lat)
	pct := func(p float64) time.Duration {
		if len(lat) == 0 {
			return 0
		}
		return lat[min(len(lat)-1, int(p*float64(len(lat))))]
	}
	ms := func(d time.Duration) string { return fmt.Sprintf("%.2fms", float64(d)/float64(time.Millisecond)) }

	fmt.Println()
	fmt.Printf("elapsed      %.2fs\n", elapsed.Seconds())
	fmt.Printf("throughput   %.0f transfers/s  (%.0f batches/s)\n",
		float64(transfers)/elapsed.Seconds(), float64(len(lat))/elapsed.Seconds())
	fmt.Printf("batch p50 %s  p95 %s  p99 %s  max %s\n", ms(pct(0.50)), ms(pct(0.95)), ms(pct(0.99)), ms(pct(1)))
	fmt.Printf("retries      %d\n", retries)
}

func verify(ctx context.Context, pool *pgxpool.Pool, cfg config) error {
	if cfg.reset {
		var count int64
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM ledger.transfers`).Scan(&count); err != nil {
			return fmt.Errorf("verify: %w", err)
		}
		if count != int64(cfg.transfers) {
			return fmt.Errorf("verify: expected %d transfers, found %d", cfg.transfers, count)
		}
	}
	// Every account's latest balance must equal the sum of its transfers, and its version must
	// equal its transfer count. A lost update or skipped version under concurrency shows up here;
	// a global debits == credits check would not catch it, since each transfer posts both sides.
	var mismatched int64
	if err := pool.QueryRow(ctx, `
		WITH latest AS (
		    SELECT DISTINCT ON (account_id) account_id, version, debits_posted, credits_posted
		    FROM ledger.account_balances
		    ORDER BY account_id, version DESC
		), flows AS (
		    SELECT debit_account_id AS account_id, sum(amount) AS debits, 0 AS credits, count(*) AS n
		    FROM ledger.transfers GROUP BY debit_account_id
		    UNION ALL
		    SELECT credit_account_id, 0, sum(amount), count(*)
		    FROM ledger.transfers GROUP BY credit_account_id
		), expected AS (
		    SELECT account_id, sum(debits) AS debits, sum(credits) AS credits, sum(n) AS n
		    FROM flows GROUP BY account_id
		)
		SELECT count(*)
		FROM latest l FULL JOIN expected e USING (account_id)
		WHERE l.debits_posted IS DISTINCT FROM e.debits
		   OR l.credits_posted IS DISTINCT FROM e.credits
		   OR l.version IS DISTINCT FROM e.n`).Scan(&mismatched); err != nil {
		return fmt.Errorf("verify: %w", err)
	}
	if mismatched > 0 {
		return fmt.Errorf("verify: %d accounts have balances that don't match their transfers", mismatched)
	}
	fmt.Println("verify       ok (transfer count matches, every account balance matches its transfers)")
	return nil
}
