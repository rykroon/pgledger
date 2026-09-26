# pgledger bench

Measures how fast pgledger posts transfers, and checks that what it posted is consistent.

Each run starts a throwaway `supabase/postgres` container, installs the extension from the
working tree through pg_tle (the same route as `supabase/migrations`), creates ledgers and
accounts, posts transfers from N concurrent connections, prints a report, verifies the ledger,
and removes the container. Requires Docker and Go.

```sh
cd bench
go run .                                   # 8 clients, 1 ledger, 1000 accounts, 100k transfers
go run . -clients 32 -accounts 10 -hot-ratio 1   # lock contention on one hot account
go run . -batch 100 -transfers 1000000     # one INSERT per 100 transfers
go run . -rules -fund 1000 -amount-max 5000     # balance rules with rejections
go run . -ledgers 8 -ledger-skew 1.2 -json # traffic concentrated on a few ledgers, JSON out
```

## What each knob measures

| flag | default | what it exercises |
|---|---|---|
| `-clients` | 8 | concurrent connections, one goroutine each; every statement is its own transaction |
| `-transfers` | 100000 | transfers in the timed run, split evenly across clients |
| `-batch` | 1 | transfers per `INSERT`. The trigger locks the touched accounts and runs once per statement, so this is the main lever |
| `-ledgers` | 1 | ledgers; accounts are split evenly across them |
| `-ledger-skew` | 0 | zipf exponent for choosing a transfer's ledger. 0 is uniform; 1 or more piles traffic onto the first ledgers |
| `-accounts` | 1000 | total accounts across all ledgers |
| `-hot-ratio` | 0 | fraction of transfers with one side on a hot account of its ledger. Posting serializes per account, so this is the contention knob |
| `-hot-accounts` | 1 | hot accounts per ledger |
| `-rules` | off | accounts get `require_debit_balance`; a per-ledger unrestricted reserve funds each account with `-fund` before the timed run. Exercises `check_balance_rule` and the rollback path. Rejected batches are counted, never retried |
| `-history-ratio` | 1 | fraction of each ledger's accounts that keep history, so posting to them also appends to `account_balances`; the rest keep only their totals on `accounts`. Spread evenly over hot, then normal, then reserve accounts, so at mixed ratios whether a hot account has history follows from its position; use 0 or 1 for clean hot-account runs |
| `-amount-max` | 100 | amounts are uniform in `1..amount-max`; raise it past `-fund` to force rejections |
| `-uuid` | v7 | `v4` (random) or `v7` (time-ordered) ids, which changes how the uuid btrees grow |
| `-warmup` | 0 | transfers posted before timing starts |
| `-seed` | clock | reproduces the workload (which accounts, which amounts); ids are still fresh |
| `-verify` | on | invariant checks after the run |
| `-json` | off | machine-readable report |

Container and install flags:

| flag | default | |
|---|---|---|
| `-image` | `public.ecr.aws/supabase/postgres:17.6.1.167` | image to run |
| `-port` | 54332 | host port; `supabase start` uses 54322 |
| `-name` | `pgledger-bench` | container name |
| `-keep` | off | leave the container running; a later run with the same name reuses it and reinstalls the extension |
| `-pg k=v` | none | postgres setting passed as `-c` to the container, repeatable, e.g. `-pg max_connections=300 -pg shared_buffers=1GB` |
| `-dsn` | none | benchmark an existing database instead. Refuses to run without `-reset-existing`, because every run drops and reinstalls pgledger there |
| `-schema` | `ledger` | schema the extension is installed into |
| `-ext-dir` | nearest ancestor with `pgledger.control` | where to read the extension from |

The stock image allows 100 connections; the bench refuses to start more clients than fit and
tells you which `-pg max_connections` to pass.

## Reading the report

```
run:    200000 transfers in 8.18s  =>  24448 transfers/s, 244 statements/s
latency/statement: p50 23.53ms  p90 63.73ms  p99 142.03ms  max 289.70ms
errors: 0 of 2000 statements failed (0 of 200000 transfers not posted)
server: commits +2024 rollbacks +0 deadlocks +0 blks_hit +14703396 blks_read +36
        transfers         43.9 MB total, 27.0 MB table, 16.9 MB indexes
        account_balances  83.3 MB total, 32.2 MB table, 51.1 MB indexes
verify: OK
```

- **transfers/s** counts only posted rows; a batch rejected by a balance rule contributes zero.
- **latency** is per statement, so with `-batch 100` one latency covers 100 transfers.
- **errors** are grouped by SQLSTATE with one sample message each. `P0001` is a balance rule,
  `40P01` a deadlock, `23505` a unique violation. Single-statement posting must never deadlock.
- **server** shows deltas from `pg_stat_database` around the timed run, and relation sizes at the
  end so the cost of the indexes is visible.
- **verify** checks that every ledger sums to zero, that there is one transfer row per posted
  transfer and one `account_balances` row per leg on a history account (funding and warmup
  included), that each account's totals equal the sums of its transfers, that each account's
  `version` is gapless, and that no deadlock occurred. A failed check exits with status 3.

Ledgers and accounts are created fresh every run, and every row carries the run id in
`external_id`. Because the tables are append-only, a reused container is cleared by dropping
and reinstalling the extension, not by truncating.
