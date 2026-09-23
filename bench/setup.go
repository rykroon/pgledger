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
	ledger       uuid.UUID
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

// setupWorld creates the ledgers and accounts for this run and, with -rules, funds every
// account from its ledger's reserve so the timed run starts from a solvent ledger.
func setupWorld(ctx context.Context, cfg *config, conns []*pgx.Conn, runID uuid.UUID, rep *report) (*world, error) {
	w := &world{runID: runID}
	t0 := time.Now()

	// Ledgers, with zipf weights 1/(rank+1)^skew for -ledger-skew.
	ledgerIDs := make([]uuid.UUID, cfg.ledgers)
	var total float64
	for i := range ledgerIDs {
		ledgerIDs[i] = newID(cfg.uuidVersion)
		w.ledgers = append(w.ledgers, &ledgerSet{id: ledgerIDs[i]})
		total += 1 / math.Pow(float64(i+1), cfg.ledgerSkew)
		w.cum = append(w.cum, total)
	}
	ledgerSQL := fmt.Sprintf("INSERT INTO %s.ledgers (id) SELECT unnest($1::uuid[])", pgx.Identifier{cfg.schema}.Sanitize())
	if _, err := conns[0].Exec(ctx, ledgerSQL, ledgerIDs); err != nil {
		return nil, fmt.Errorf("create ledgers: %w", err)
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
	accountSQL := fmt.Sprintf(`INSERT INTO %s.accounts (id, ledger_id, code, external_id, require_debit_balance)
SELECT * FROM unnest($1::uuid[], $2::uuid[], $3::int[], $4::uuid[], $5::bool[])`, pgx.Identifier{cfg.schema}.Sanitize())
	err := parallel(ctx, len(conns), func(ctx context.Context, i int) error {
		for chunk := range chunks {
			n := len(chunk)
			ids, ledgers, ext := make([]uuid.UUID, n), make([]uuid.UUID, n), make([]uuid.UUID, n)
			codes, rules := make([]int32, n), make([]bool, n)
			for k, r := range chunk {
				ids[k], ledgers[k], codes[k], ext[k], rules[k] = r.id, r.ledger, r.code, runID, r.requireDebit
			}
			if _, err := conns[i].Exec(ctx, accountSQL, ids, ledgers, codes, ext, rules); err != nil {
				return fmt.Errorf("create accounts: %w", err)
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
			if err := postBatch(ctx, conns[i], sql, batch, runID); err != nil {
				return fmt.Errorf("fund accounts: %w", err)
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
