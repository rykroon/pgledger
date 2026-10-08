# pgledger

A double-entry ledger for Postgres, inspired by [TigerBeetle](https://docs.tigerbeetle.com/),
shipped as a single-script [Trusted Language Extension](https://github.com/aws/pg_tle)
(pure SQL/plpgsql, no superuser required).

## Install

As a regular extension (the control file and script in this repo go in your extension
directory), or through pg_tle on managed providers:

```sql
CREATE SCHEMA ledger;
CREATE EXTENSION pgledger SCHEMA ledger;
```

## Usage

```sql
-- cash: debit-normal, credits may never exceed debits.
SELECT * FROM ledger.create_account(ledger => 1, code => 100, require_debit_balance => true);
-- revenue: credit-normal, debits may never exceed credits.
SELECT * FROM ledger.create_account(ledger => 1, code => 400, require_credit_balance => true);

-- A sale: cash is debited, revenue is credited.
SELECT * FROM ledger.create_transfer(
    debit_account_id => '<cash id>',
    credit_account_id => '<revenue id>',
    amount => 100,
    code => 1);

SELECT * FROM ledger.get_account_balance('<cash id>');
```

Batches go through `create_accounts(account_input[])` and
`create_transfers(transfer_input[])`. A batch shares your transaction, so its transfers
all succeed or fail together (TigerBeetle's "linked" behavior). See `supabase/seed.sql`
for a worked example.

Reading things back: `lookup_account(s)`, `lookup_transfer(s)`,
`get_account_balance(account_id)` (latest), `get_account_balances(account_id, ...)`
(full history, newest first), and `get_account_transfers(account_id, ...)`.

## Design

- **Append-only.** `UPDATE`, `DELETE`, and `TRUNCATE` on the ledger tables are blocked by
  triggers. `transfers` and `account_balances` additionally reject direct `INSERT`s, so the
  only way to move money is `create_transfer()`/`create_transfers()`, which maintain the
  balance bookkeeping.
- **History is always on.** Every transfer appends a row per affected account to
  `account_balances`, keyed by `(account_id, version)` where `version` is a per-account
  counter. The latest row is the current balance.
- **Concurrency without deadlocks.** Transfers lock their account rows
  (`FOR NO KEY UPDATE`) in ascending id order; batches pre-lock every account they touch
  the same way. Concurrent transfers over the same accounts serialize per account instead
  of deadlocking.
- **Account flags.** `require_credit_balance` (debits may never exceed credits) and
  `require_debit_balance` (credits may never exceed debits), mutually exclusive — TigerBeetle's
  `debits_must_not_exceed_credits` / `credits_must_not_exceed_debits`.
- **Transfer flags.** `balance_debit_account` / `balance_credit_account` treat `amount` as a
  maximum and cap it so the account's balance is not pushed past zero — TigerBeetle's
  `balancing_debit` / `balancing_credit`.
- **Types.** Ids are UUIDv7 (time-ordered, generated when you don't supply one), amounts are
  `numeric(39,0) >= 0` (TigerBeetle's uint128 range), ledgers are positive `integer`s, codes
  are `numeric(5,0)` to fit chart-of-accounts conventions, and both tables carry optional
  `external_id uuid` / `external_timestamp timestamptz` user-data columns.
- **Same-ledger transfers only**, enforced declaratively: transfers reference
  `accounts (id, ledger)` for both sides.

## Development

The `supabase` directory is a local sandbox (db on port 54332):

```sh
supabase start
scripts/gen-tle-migration.sh   # after editing pgledger--0.0.1.sql
supabase db reset              # install the extension + seed
supabase test db               # pgTAP suite in supabase/tests/
```

## Benchmarking

`bench/` holds a Go load generator that measures write throughput (transfers/second) through
`create_transfers()`. `bench/run.sh` starts a throwaway `postgres:17` container (2 CPUs, 6 GiB —
TigerBeetle's replica minimum) with this repo's extension files mounted in, runs the benchmark,
and removes the container. Arguments pass straight through:

```sh
bench/run.sh                                   # 16 clients, batches of 100, 100k transfers
bench/run.sh -clients 32 -batch 50 -hot-ratio 0.5
KEEP=1 PG_ARGS="-c synchronous_commit=off" bench/run.sh -transfers 1000000
```

| flag | default | |
|---|---|---|
| `-clients` | 16 | concurrent connections |
| `-batch` | 100 | transfers per `create_transfers()` call |
| `-hot-ratio` | 0 | fraction of transfers touching a hot account (0 = uniform random, 1 = all) |
| `-transfers` | 100000 | total transfers |
| `-accounts` | 10000 | accounts created up front |
| `-hot-accounts` | 1 | size of the hot set |
| `-reset` | true | drop and reinstall the extension first |
| `-seed` | clock | RNG seed |
| `-progress` | 1s | progress interval (0 disables) |
| `-verify` | true | afterwards, check the transfer count and that every account balance matches its transfers |

Container knobs are environment variables: `PG_IMAGE`, `PG_PORT` (54329), `PG_CPUS`,
`PG_MEMORY`, `PG_ARGS`, `KEEP=1`.

Caveats: on macOS every round trip crosses Docker Desktop's VM, so larger batches amortize
that overhead; compare runs on the same machine rather than reading absolute numbers. A batch
locks every account it touches for its whole transaction, so with large batches even a
"random" workload contends across clients.
