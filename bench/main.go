// pgledger-bench measures posting throughput of the pgledger extension.
//
// By default it starts a throwaway supabase/postgres container, installs the working-tree
// extension through pg_tle, creates ledgers and accounts, posts transfers from N concurrent
// clients, reports throughput and latency, verifies the ledger, and removes the container.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

type stringList []string

func (s *stringList) String() string     { return strings.Join(*s, ",") }
func (s *stringList) Set(v string) error { *s = append(*s, v); return nil }

type config struct {
	// workload
	clients      int
	ledgers      int
	accounts     int
	transfers    int
	batch        int
	ledgerSkew   float64
	hotRatio     float64
	hotAccounts  int
	rules        bool
	historyRatio float64
	fund         int64
	amountMax    int64
	uuidVersion  string
	warmup       int
	seed         int64
	verify       bool
	jsonOut      bool

	// container / install
	image         string
	port          int
	name          string
	keep          bool
	pgOpts        stringList
	dsn           string
	resetExisting bool
	schema        string
	extDir        string
}

func parseFlags() (*config, error) {
	c := &config{}
	flag.IntVar(&c.clients, "clients", 8, "concurrent client connections")
	flag.IntVar(&c.ledgers, "ledgers", 1, "number of ledgers; accounts are split evenly across them")
	flag.IntVar(&c.accounts, "accounts", 1000, "total accounts (hot accounts included, reserve accounts excluded)")
	flag.IntVar(&c.transfers, "transfers", 100000, "total transfers to post in the timed run")
	flag.IntVar(&c.batch, "batch", 1, "transfers per INSERT statement")
	flag.Float64Var(&c.ledgerSkew, "ledger-skew", 0, "zipf exponent for picking a transfer's ledger; 0 = uniform")
	flag.Float64Var(&c.hotRatio, "hot-ratio", 0, "fraction of transfers with one side on a hot account of its ledger")
	flag.IntVar(&c.hotAccounts, "hot-accounts", 1, "hot accounts per ledger")
	flag.BoolVar(&c.rules, "rules", false, "accounts require a debit balance and are funded from an unrestricted reserve per ledger")
	flag.Float64Var(&c.historyRatio, "history-ratio", 1, "fraction of each ledger's accounts that keep history, spread evenly")
	flag.Int64Var(&c.fund, "fund", 1000000, "initial funding per account when -rules is set")
	flag.Int64Var(&c.amountMax, "amount-max", 100, "transfer amounts are uniform in 1..amount-max")
	flag.StringVar(&c.uuidVersion, "uuid", "v7", "id generation: v4 (random) or v7 (time-ordered)")
	flag.IntVar(&c.warmup, "warmup", 0, "transfers posted before the timed run, not counted")
	flag.Int64Var(&c.seed, "seed", 0, "workload seed; 0 = derived from the clock")
	flag.BoolVar(&c.verify, "verify", true, "check ledger invariants after the run")
	flag.BoolVar(&c.jsonOut, "json", false, "print the report as JSON")

	flag.StringVar(&c.image, "image", "public.ecr.aws/supabase/postgres:17.6.1.167", "postgres image to run")
	flag.IntVar(&c.port, "port", 54332, "host port to publish the container on")
	flag.StringVar(&c.name, "name", "pgledger-bench", "container name")
	flag.BoolVar(&c.keep, "keep", false, "leave the container running; a later run reuses it")
	flag.Var(&c.pgOpts, "pg", "postgres setting k=v passed as -c to the container (repeatable)")
	flag.StringVar(&c.dsn, "dsn", "", "use an existing database instead of a container (requires -reset-existing)")
	flag.BoolVar(&c.resetExisting, "reset-existing", false, "with -dsn: acknowledge that pgledger is dropped and reinstalled there")
	flag.StringVar(&c.schema, "schema", "ledger", "schema to install pgledger into")
	flag.StringVar(&c.extDir, "ext-dir", "", "directory holding pgledger.control (default: nearest ancestor of the cwd)")
	flag.Parse()

	if c.clients < 1 || c.ledgers < 1 || c.batch < 1 || c.hotAccounts < 0 {
		return nil, errors.New("clients, ledgers and batch must be >= 1; hot-accounts >= 0")
	}
	if c.transfers < 0 || c.warmup < 0 {
		return nil, errors.New("transfers and warmup must be >= 0")
	}
	if c.accounts < c.ledgers*2 {
		return nil, fmt.Errorf("accounts must be at least 2 per ledger (%d ledgers)", c.ledgers)
	}
	if c.hotRatio < 0 || c.hotRatio > 1 || c.ledgerSkew < 0 {
		return nil, errors.New("hot-ratio must be in [0,1] and ledger-skew >= 0")
	}
	if c.historyRatio < 0 || c.historyRatio > 1 {
		return nil, errors.New("history-ratio must be in [0,1]")
	}
	perLedger := c.accounts / c.ledgers
	if c.hotRatio > 0 && (c.hotAccounts < 1 || perLedger < c.hotAccounts+1) {
		return nil, fmt.Errorf("hot-ratio > 0 needs 1..%d hot accounts with %d accounts per ledger", perLedger-1, perLedger)
	}
	if c.hotAccounts >= perLedger {
		c.hotAccounts = 0 // no room for a non-hot counterparty; everything is "normal"
	}
	if c.amountMax < 1 || c.fund < 1 {
		return nil, errors.New("amount-max and fund must be >= 1")
	}
	if c.uuidVersion != "v4" && c.uuidVersion != "v7" {
		return nil, errors.New("uuid must be v4 or v7")
	}
	if c.dsn != "" && !c.resetExisting {
		return nil, errors.New("-dsn drops and reinstalls pgledger in that database; pass -reset-existing to confirm")
	}
	if c.seed == 0 {
		c.seed = time.Now().UnixNano()
	}
	return c, nil
}

func main() {
	log.SetFlags(log.Ltime)
	log.SetOutput(os.Stderr)

	cfg, err := parseFlags()
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		flag.Usage()
		os.Exit(2)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := run(ctx, cfg); err != nil {
		if errors.Is(err, errVerifyFailed) {
			fmt.Fprintln(os.Stderr, "verify: FAILED")
			os.Exit(3)
		}
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, cfg *config) error {
	ext, err := loadExtension(cfg.extDir)
	if err != nil {
		return err
	}

	dsn := cfg.dsn
	if dsn == "" {
		ctr, err := ensureContainer(ctx, cfg)
		if err != nil {
			return err
		}
		if !cfg.keep {
			defer ctr.remove()
		}
		dsn = ctr.dsn()
	}

	admin, err := pgx.Connect(ctx, dsn)
	if err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	defer admin.Close(context.Background())

	var maxConn int
	if err := admin.QueryRow(ctx, "SELECT current_setting('max_connections')::int").Scan(&maxConn); err != nil {
		return err
	}
	if cfg.clients+5 > maxConn {
		return fmt.Errorf("clients=%d needs more than max_connections=%d; pass -pg max_connections=%d", cfg.clients, maxConn, cfg.clients+20)
	}

	log.Printf("installing pgledger %s into schema %q", ext.version, cfg.schema)
	if err := installExtension(ctx, admin, ext, cfg.schema); err != nil {
		return err
	}

	conns := make([]*pgx.Conn, cfg.clients)
	for i := range conns {
		c, err := pgx.Connect(ctx, dsn)
		if err != nil {
			return fmt.Errorf("connect client %d: %w", i, err)
		}
		conns[i] = c
		defer c.Close(context.Background())
	}

	runID := uuid.New()
	rep := &report{RunID: runID.String(), Seed: cfg.seed, Config: cfg}
	if err := admin.QueryRow(ctx, "SELECT current_setting('server_version')").Scan(&rep.ServerVersion); err != nil {
		return err
	}

	log.Printf("creating %d ledgers and %d accounts", cfg.ledgers, cfg.accounts)
	w, err := setupWorld(ctx, cfg, conns, runID, rep)
	if err != nil {
		return err
	}

	if cfg.warmup > 0 {
		log.Printf("warmup: posting %d transfers", cfg.warmup)
		r := runPhase(ctx, cfg, conns, w, cfg.warmup, cfg.seed+1)
		rep.postedTotal += r.posted
	}

	before, err := readServerStats(ctx, admin, cfg.schema)
	if err != nil {
		return err
	}

	log.Printf("run: posting %d transfers from %d clients, batch %d", cfg.transfers, cfg.clients, cfg.batch)
	res := runPhase(ctx, cfg, conns, w, cfg.transfers, cfg.seed)
	rep.postedTotal += res.posted
	rep.fillRun(res)

	after, err := readServerStats(ctx, admin, cfg.schema)
	if err != nil {
		return err
	}
	rep.Server = after.delta(before)

	if cfg.verify {
		log.Printf("verifying")
		if err := verify(ctx, admin, cfg.schema, rep); err != nil {
			return err
		}
	}

	if cfg.jsonOut {
		return rep.writeJSON(os.Stdout)
	}
	rep.writeText(os.Stdout)
	if cfg.verify && !rep.Verify.OK {
		return errVerifyFailed
	}
	return nil
}
