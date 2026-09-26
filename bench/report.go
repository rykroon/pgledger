package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

var errVerifyFailed = errors.New("verification failed")

type report struct {
	RunID         string         `json:"run_id"`
	Seed          int64          `json:"seed"`
	ServerVersion string         `json:"server_version"`
	Config        *config        `json:"-"`
	Params        map[string]any `json:"params"`
	Setup         struct {
		Ledgers          int     `json:"ledgers"`
		Accounts         int     `json:"accounts"`
		Seconds          float64 `json:"seconds"`
		AccountsPerSec   float64 `json:"accounts_per_sec"`
		FundingTransfers int64   `json:"funding_transfers"`
		FundingSeconds   float64 `json:"funding_seconds"`
	} `json:"setup"`
	Run struct {
		Seconds          float64           `json:"seconds"`
		Statements       int               `json:"statements"`
		FailedStatements int               `json:"failed_statements"`
		Attempted        int64             `json:"transfers_attempted"`
		Posted           int64             `json:"transfers_posted"`
		TransfersPerSec  float64           `json:"transfers_per_sec"`
		StatementsPerSec float64           `json:"statements_per_sec"`
		LatencyMs        latency           `json:"statement_latency_ms"`
		Errors           map[string]int    `json:"errors_by_sqlstate"`
		ErrorSamples     map[string]string `json:"error_samples"`
	} `json:"run"`
	Server serverDelta  `json:"server"`
	Verify verifyResult `json:"verify"`

	postedTotal int64 // funding + warmup + run, for verification
}

type latency struct {
	P50 float64 `json:"p50"`
	P90 float64 `json:"p90"`
	P99 float64 `json:"p99"`
	Max float64 `json:"max"`
}

func (r *report) fillRun(res phaseResult) {
	r.Params = r.Config.params()
	r.Run.Seconds = res.wall.Seconds()
	r.Run.Statements = res.statements
	r.Run.FailedStatements = res.failed
	r.Run.Attempted = res.attempted
	r.Run.Posted = res.posted
	r.Run.TransfersPerSec = float64(res.posted) / res.wall.Seconds()
	r.Run.StatementsPerSec = float64(res.statements) / res.wall.Seconds()
	r.Run.Errors = res.errs
	r.Run.ErrorSamples = res.samples
	if n := len(res.lat); n > 0 {
		q := func(p float64) float64 { return float64(res.lat[int(p*float64(n-1))]) / float64(time.Millisecond) }
		r.Run.LatencyMs = latency{P50: q(0.50), P90: q(0.90), P99: q(0.99), Max: q(1)}
	}
}

func (c *config) params() map[string]any {
	return map[string]any{
		"clients": c.clients, "ledgers": c.ledgers, "accounts": c.accounts, "transfers": c.transfers,
		"batch": c.batch, "ledger_skew": c.ledgerSkew, "hot_ratio": c.hotRatio, "hot_accounts": c.hotAccounts,
		"rules": c.rules, "fund": c.fund, "amount_max": c.amountMax, "uuid": c.uuidVersion, "warmup": c.warmup,
		"image": c.image, "pg": []string(c.pgOpts), "schema": c.schema,
	}
}

// Server-side counters around the timed run. pg_stat_database is flushed by each backend at
// the end of its work, so the deltas cover the run but can include a little of setup's tail.
type serverStats struct {
	Commits   int64 `json:"commits"`
	Rollbacks int64 `json:"rollbacks"`
	Deadlocks int64 `json:"deadlocks"`
	BlksRead  int64 `json:"blks_read"`
	BlksHit   int64 `json:"blks_hit"`
	sizes     map[string][2]int64
}

type serverDelta struct {
	serverStats
	Sizes map[string]relSize `json:"sizes"`
}

type relSize struct {
	TotalBytes int64 `json:"total_bytes"`
	TableBytes int64 `json:"table_bytes"`
}

func readServerStats(ctx context.Context, conn *pgx.Conn, schema string) (serverStats, error) {
	var s serverStats
	err := conn.QueryRow(ctx, `SELECT xact_commit, xact_rollback, deadlocks, blks_read, blks_hit
FROM pg_stat_database WHERE datname = current_database()`).Scan(&s.Commits, &s.Rollbacks, &s.Deadlocks, &s.BlksRead, &s.BlksHit)
	if err != nil {
		return s, fmt.Errorf("pg_stat_database: %w", err)
	}
	s.sizes = map[string][2]int64{}
	for _, rel := range []string{"transfers", "account_balances", "accounts"} {
		q := pgx.Identifier{schema, rel}.Sanitize()
		var total, table int64
		if err := conn.QueryRow(ctx, "SELECT pg_total_relation_size($1), pg_relation_size($1)", q).Scan(&total, &table); err != nil {
			return s, fmt.Errorf("size of %s: %w", q, err)
		}
		s.sizes[rel] = [2]int64{total, table}
	}
	return s, nil
}

func (after serverStats) delta(before serverStats) serverDelta {
	d := serverDelta{Sizes: map[string]relSize{}}
	d.Commits = after.Commits - before.Commits
	d.Rollbacks = after.Rollbacks - before.Rollbacks
	d.Deadlocks = after.Deadlocks - before.Deadlocks
	d.BlksRead = after.BlksRead - before.BlksRead
	d.BlksHit = after.BlksHit - before.BlksHit
	for rel, sz := range after.sizes {
		d.Sizes[rel] = relSize{TotalBytes: sz[0], TableBytes: sz[1]}
	}
	return d
}

type verifyResult struct {
	OK     bool    `json:"ok"`
	Checks []check `json:"checks"`
}

type check struct {
	Name   string `json:"name"`
	OK     bool   `json:"ok"`
	Detail string `json:"detail"`
}

// verify checks the invariants the trigger design promises: every ledger sums to zero, one
// transfer row per posted transfer and one balance row per leg on a history account, account
// totals that match the transfers, gapless per-account versions, and no deadlocks from
// single-statement posting.
func verify(ctx context.Context, conn *pgx.Conn, schema string, rep *report) error {
	q := func(rel string) string { return pgx.Identifier{schema, rel}.Sanitize() }
	count := func(sql string) (int64, error) {
		var n int64
		err := conn.QueryRow(ctx, sql).Scan(&n)
		return n, err
	}
	var v verifyResult
	add := func(name string, ok bool, detail string) {
		v.Checks = append(v.Checks, check{Name: name, OK: ok, Detail: detail})
	}

	n, err := count("SELECT count(*) FROM (SELECT ledger_id FROM " + q("current_balances") + " GROUP BY 1 HAVING sum(balance) <> 0) x")
	if err != nil {
		return err
	}
	add("ledgers balance to zero", n == 0, fmt.Sprintf("%d unbalanced", n))

	n, err = count("SELECT count(*) FROM " + q("transfers"))
	if err != nil {
		return err
	}
	add("transfer rows match posted", n == rep.postedTotal, fmt.Sprintf("%d rows, %d posted", n, rep.postedTotal))

	n, err = count("SELECT count(*) FROM " + q("account_balances"))
	if err != nil {
		return err
	}
	wantBalanceRows, err := count(`SELECT count(*) FROM ` + q("transfers") + ` t
JOIN ` + q("accounts") + ` a ON a.id IN (t.debit_account_id, t.credit_account_id)
WHERE a.history`)
	if err != nil {
		return err
	}
	add("balance rows match history", n == wantBalanceRows, fmt.Sprintf("%d rows, %d expected", n, wantBalanceRows))

	n, err = count(`SELECT count(*) FROM ` + q("accounts") + ` a
LEFT JOIN (SELECT debit_account_id AS id, sum(amount) AS s FROM ` + q("transfers") + ` GROUP BY 1) d ON d.id = a.id
LEFT JOIN (SELECT credit_account_id AS id, sum(amount) AS s FROM ` + q("transfers") + ` GROUP BY 1) c ON c.id = a.id
WHERE a.debits_posted <> COALESCE(d.s, 0) OR a.credits_posted <> COALESCE(c.s, 0)`)
	if err != nil {
		return err
	}
	add("account totals match transfers", n == 0, fmt.Sprintf("%d accounts off", n))

	n, err = count("SELECT count(*) FROM (SELECT account_id FROM " + q("account_balances") + " GROUP BY 1 HAVING max(version) <> count(*)) x")
	if err != nil {
		return err
	}
	add("versions gapless per account", n == 0, fmt.Sprintf("%d accounts with gaps or forks", n))

	dl := rep.Run.Errors["40P01"]
	add("no deadlocks", dl == 0 && rep.Server.Deadlocks == 0, fmt.Sprintf("%d client, %d server", dl, rep.Server.Deadlocks))

	v.OK = true
	for _, c := range v.Checks {
		v.OK = v.OK && c.OK
	}
	rep.Verify = v
	return nil
}

func (r *report) writeJSON(w io.Writer) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(r)
}

func mb(b int64) string { return fmt.Sprintf("%.1f MB", float64(b)/(1<<20)) }

func (r *report) writeText(w io.Writer) {
	c := r.Config
	fmt.Fprintf(w, "pgledger bench  run=%s  seed=%d  postgres %s\n", r.RunID, r.Seed, r.ServerVersion)
	fmt.Fprintf(w, "config: clients=%d ledgers=%d accounts=%d transfers=%d batch=%d ledger-skew=%g hot-ratio=%g hot-accounts=%d rules=%t uuid=%s amount-max=%d",
		c.clients, c.ledgers, c.accounts, c.transfers, c.batch, c.ledgerSkew, c.hotRatio, c.hotAccounts, c.rules, c.uuidVersion, c.amountMax)
	if c.rules {
		fmt.Fprintf(w, " fund=%d", c.fund)
	}
	if len(c.pgOpts) > 0 {
		fmt.Fprintf(w, " pg=[%s]", strings.Join(c.pgOpts, " "))
	}
	fmt.Fprintln(w)

	fmt.Fprintf(w, "setup:  %d ledgers, %d accounts in %.2fs (%.0f accounts/s)", r.Setup.Ledgers, r.Setup.Accounts, r.Setup.Seconds, r.Setup.AccountsPerSec)
	if r.Setup.FundingTransfers > 0 {
		fmt.Fprintf(w, "; funded %d accounts in %.2fs (%.0f transfers/s)", r.Setup.FundingTransfers, r.Setup.FundingSeconds, float64(r.Setup.FundingTransfers)/r.Setup.FundingSeconds)
	}
	fmt.Fprintln(w)

	fmt.Fprintf(w, "run:    %d transfers in %.2fs  =>  %.0f transfers/s, %.0f statements/s\n", r.Run.Posted, r.Run.Seconds, r.Run.TransfersPerSec, r.Run.StatementsPerSec)
	l := r.Run.LatencyMs
	fmt.Fprintf(w, "latency/statement: p50 %.2fms  p90 %.2fms  p99 %.2fms  max %.2fms\n", l.P50, l.P90, l.P99, l.Max)

	fmt.Fprintf(w, "errors: %d of %d statements failed (%d of %d transfers not posted)", r.Run.FailedStatements, r.Run.Statements, r.Run.Attempted-r.Run.Posted, r.Run.Attempted)
	if len(r.Run.Errors) > 0 {
		codes := make([]string, 0, len(r.Run.Errors))
		for k := range r.Run.Errors {
			codes = append(codes, k)
		}
		sort.Strings(codes)
		parts := make([]string, len(codes))
		for i, k := range codes {
			parts[i] = fmt.Sprintf("%s: %d", k, r.Run.Errors[k])
		}
		fmt.Fprintf(w, "  [%s]", strings.Join(parts, ", "))
		fmt.Fprintln(w)
		for _, k := range codes {
			fmt.Fprintf(w, "        %s e.g. %s\n", k, r.Run.ErrorSamples[k])
		}
	} else {
		fmt.Fprintln(w)
	}

	s := r.Server
	fmt.Fprintf(w, "server: commits +%d rollbacks +%d deadlocks +%d blks_hit +%d blks_read +%d\n", s.Commits, s.Rollbacks, s.Deadlocks, s.BlksHit, s.BlksRead)
	for _, rel := range []string{"transfers", "account_balances", "accounts"} {
		sz := s.Sizes[rel]
		fmt.Fprintf(w, "        %-17s %s total, %s table, %s indexes\n", rel, mb(sz.TotalBytes), mb(sz.TableBytes), mb(sz.TotalBytes-sz.TableBytes))
	}

	if r.Verify.Checks != nil {
		status := "OK"
		if !r.Verify.OK {
			status = "FAILED"
		}
		fmt.Fprintf(w, "verify: %s\n", status)
		for _, c := range r.Verify.Checks {
			mark := "ok  "
			if !c.OK {
				mark = "FAIL"
			}
			fmt.Fprintf(w, "        %s %s (%s)\n", mark, c.Name, c.Detail)
		}
	}
}
