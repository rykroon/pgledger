# pgledger

A double-entry ledger for Postgres, inspired by [TigerBeetle](https://tigerbeetle.com/).

Every transfer moves value from a credit account to a debit account, and both sides are
recorded. Nothing is ever updated or deleted — accounts, transfers, and balances are all append-only, so the full history stays readable.

## Install

pgledger installs into a schema of your choosing. The schema must already exist:

```sql
CREATE SCHEMA ledger;
CREATE EXTENSION pgledger SCHEMA ledger;
```

Any name works — `CREATE EXTENSION pgledger SCHEMA accounting;` puts every object in
`accounting` instead. Omitting the `SCHEMA` clause installs into the current default
creation schema, usually `public`. The examples below assume you chose `ledger`.

## Usage

A ledger holds accounts in a single unit of value, such as a currency, points, or inventory.
The extension doesn't dictate how you structure them: you tell accounts apart with your own
`code`s and `external_id`, and choose a balance rule for each one.

A ledger is just a positive integer you choose, like TigerBeetle's `ledger`; there is
nothing to create, and the first account that uses a number starts that ledger. Keep
attributes such as a name or currency in your own table keyed by `ledger integer`.

Create accounts with `ledger.create_accounts()`, which takes an array of
`ledger.account_input`. Each account may optionally restrict which side its balance can be
on. The fields are `id, ledger, code, external_id, external_timestamp,
require_credit_balance, require_debit_balance`:

```sql
SELECT * FROM ledger.create_accounts(ARRAY[
    -- cash (code 1 in this example): debit-normal, cannot go below zero
    ROW('...cash-id...', 1, 1, NULL, NULL, false, true)::ledger.account_input,
    -- revenue (code 2): credit-normal, cannot go below zero
    ROW('...revenue-id...', 1, 2, NULL, NULL, true, false)::ledger.account_input
]);
```

It returns one `(ord, account_id, code)` row per input, in input order. `code` is `ok` or the
first failed check: `id_not_set`, `ledger_invalid`, `code_invalid`,
`flags_are_mutually_exclusive` (both balance requirements set), or
`id_already_exists`. A rejected row doesn't stop the others from being created, and a `NULL`
balance requirement counts as `false`. When an id appears more than once in a batch, only
its first valid copy is created. A retry is safe: accounts that already exist come back as
`id_already_exists`.

Post transfers with `ledger.create_transfers()`, which takes an array of
`ledger.transfer_input`. The fields are `id, ledger, debit_account_id, credit_account_id,
amount, code, external_id, external_timestamp, balance_debit_account, balance_credit_account`. Value flows credit -> debit, so recording a sale debits cash
and credits revenue:

```sql
SELECT * FROM ledger.create_transfers(ARRAY[
    ROW('...transfer-id...', 1, '...cash-id...', '...revenue-id...',
        100, 1, NULL, NULL, false, false)::ledger.transfer_input
]);
```

It returns one `(ord, transfer_id, code)` row per input, in input order. `code` is `ok` or the
first failed check:

- the row's own values: `id_not_set`, `ledger_invalid`, `amount_must_be_positive`,
  `code_invalid`, `accounts_must_be_different`
- lookups: `id_already_exists`, `debit_account_not_found`, `credit_account_not_found`,
  `debit_account_ledger_mismatch`, `credit_account_ledger_mismatch`
- balances: `exceeds_credits`, `exceeds_debits`

Each accepted transfer is inserted into `ledger.transfers` with two new running-total rows in
`ledger.account_balances`. A rejected row doesn't stop the others from posting, and a `NULL`
balance flag counts as `false`. A batch may span ledgers.

Rows post in input order, each against the balances left by the accepted rows before it, so
order changes outcomes: a deposit followed by a withdrawal can succeed where the reverse is
rejected. A rejected row never affects the rows after it. To post all-or-nothing, check the
results and roll back the transaction if any row isn't `ok`.

A retry is safe: transfers that already exist come back as `id_already_exists` and are never
posted twice. When an id appears more than once in a batch, it posts at most once. If two
concurrent calls post the same new id, the later one fails as a whole with a unique
violation (SQLSTATE `23505`); retrying it then reports `id_already_exists`.

Read balances:

```sql
SELECT account_id, balance FROM ledger.current_balances WHERE ledger = 1;
```

`balance` is debits minus credits, so debit-normal accounts read positive and credit-normal
accounts read negative. Every transfer adds the same amount to both sides, so a ledger always
sums to zero.

For history, `ledger.account_balances` has one row per account per transfer, holding the
running `debits_posted` and `credits_posted` after that transfer. `version` counts each
account's postings from 1 and is their order; join `ledger.transfers` for `created_at`:

```sql
SELECT ab.version, ab.debits_posted - ab.credits_posted AS balance, t.created_at
FROM ledger.account_balances ab
JOIN ledger.transfers t ON t.id = ab.transfer_id
WHERE ab.account_id = '...cash-id...'
ORDER BY ab.version;
```

## Balance rules

- `require_debit_balance`: the account's credits may never exceed its debits.
- `require_credit_balance`: the account's debits may never exceed its credits.
- Neither: the balance may be on either side.

A transfer that would break a rule is rejected with `exceeds_credits` (its debit account
requires a credit balance) or `exceeds_debits` (its credit account requires a debit
balance). The debit account is checked first. The rest of the batch still posts.

## Balancing transfers

`balance_debit_account` and `balance_credit_account` on `ledger.transfers` work like
TigerBeetle's `balancing_debit` and `balancing_credit` flags: they make `amount` a maximum
rather than an exact amount, so the named account moves toward equal debits and credits.

- `balance_debit_account`: move no more than brings the debit account's debits up to its
  credits. The debit account must start with a credit balance.
- `balance_credit_account`: move no more than brings the credit account's credits up to its
  debits. The credit account must start with a debit balance.
- Both: move the smaller of the two.

Only the flagged account's balance limits the amount. It ends with equal debits and credits
when `amount` is `NULL` (no cap) or at least its balance; a smaller `amount` moves just that
much.

`balance_debit_account` is the common one: spending or paying out up to what a customer's
credit-normal wallet holds. To pay out all of it:

```sql
SELECT * FROM ledger.create_transfers(ARRAY[
    ROW('...transfer-id...', 1, '...wallet-id...', '...cash-id...',
        NULL, 3, NULL, NULL, true, false)::ledger.transfer_input
]);
```

`balance_credit_account` applies up to what is owed on a debit-normal account. A customer who
owes 100 on a loan and sends 200 has 100 applied, rather than the loan going to -100:

```sql
SELECT * FROM ledger.create_transfers(ARRAY[
    ROW('...transfer-id...', 1, '...cash-id...', '...loan-id...',
        200, 4, NULL, NULL, false, true)::ledger.transfer_input
]);
```

The amount is worked out while posting holds the account locks, against the balance left
by any earlier rows in the same batch, so there is no read-then-write race to manage. The
clamp applies whatever balance rules the accounts have, and those rules are still checked
afterwards. `ledger.transfers.amount` records what actually moved, and the stored
`balance_debit_account` and `balance_credit_account` columns record that the transfer was a
balancing one. If nothing would move, the row is rejected: with `exceeds_credits` if
`balance_debit_account` is set and that account has no credit balance, and `exceeds_debits`
otherwise.

## Your data on accounts and transfers

Accounts and transfers both carry three fields that belong to you. The ledger stores
them but never interprets them:

- `code` (required, a number from 1 to 99999): a category you define, such as a 5-digit
  chart-of-accounts number or a transfer kind (sale, refund, fee). It doesn't reference any
  table. Anything else, including a fraction, is rejected with `code_invalid`.
- `external_id` (optional `uuid`): links the row to something in your system, e.g. a
  customer, an order, or a group of related transfers.
- `external_timestamp` (optional `timestamptz`): a time of your own, such as an effective
  date or the original time of an imported record. It doesn't change the order balances
  are applied in. `created_at` is always set by the ledger, never by you, to the clock time
  the row was inserted. Rows get their own times, even within one batch, but it is not
  unique: two rows can share a microsecond.

Transfers have no total order. Within one account, `ledger.account_balances.version` is the
order of record. Across a ledger there is none, so order a transfer log by `created_at, id`
for a stable result, bearing in mind that `id` is an arbitrary tiebreak. `created_at` is
taken while posting holds the account locks, so within one account it follows `version`, but
across accounts it can disagree with the order transactions commit in.

## Concurrency

Each `create_transfers()` call locks every account its batch touches, in `id` order, until
the transaction ends. Two transactions never post to the same account at once, which is what
keeps `version` gapless and the balance rules honest. Transfers on disjoint accounts post in
parallel, and creating accounts is never blocked.

Because the locks are taken in `id` order, two concurrent calls that touch the same accounts
cannot deadlock, however their rows are ordered. That guarantee covers a single call only. A
transaction that calls `create_transfers()` several times accumulates locks call by call, so
two transactions reaching the same accounts through separate calls, in opposite order, can
deadlock and one will be rolled back with SQLSTATE `40P01`.

Prefer one call per transaction; a batch already posts in input order. When a transaction
must post in several calls, lock every account it will touch up front, in `id` order, before
the first call:

```sql
SELECT id FROM ledger.accounts
WHERE id IN ('...account-a...', '...account-b...', '...account-c...')
ORDER BY id
FOR NO KEY UPDATE;
```

The locks are held until the transaction ends, so each posting re-requests locks the
transaction already holds and never acquires one out of order.

## Constraints

- `ledger` must be a positive integer.
- Transfers cannot cross ledgers, and cannot have the same account on both sides.
- `amount` must be positive. It may be `NULL` (no cap) only on a balancing transfer.
- `code` must be from 1 to 99999.
- `created_at` is assigned by the ledger; the input types have no such field.
- An account can require a debit balance or a credit balance, but not both.
- A transfer that would break a balance rule is rejected.
- Any `UPDATE`, `DELETE`, or `TRUNCATE` on the ledger tables is rejected.
- Only `ledger.create_accounts()` writes `ledger.accounts`, and only
  `ledger.create_transfers()` writes `ledger.transfers` and `ledger.account_balances`.
  Both run as the extension's owner (`SECURITY DEFINER`); any other role that inserts
  directly is rejected, even if it has been granted `INSERT`. Grant your app roles
  `EXECUTE` on the functions, not `INSERT` on the tables.

## Tests

`supabase/tests/` holds [pgTAP](https://pgtap.org/) tests, run against the local Supabase
database, where pgledger is installed through pg_tle exactly as the migrations do it. Each file
runs in a transaction that rolls back.

```sh
supabase start
supabase test db
```

After editing `pgledger--0.0.1.sql`, regenerate the install migration and reset first:

```sh
scripts/gen-tle-migration.sh && supabase db reset && supabase test db
```

## Benchmark

`bench/` holds a Go program that starts a throwaway `supabase/postgres` container, installs the
extension from the working tree, and posts transfers from concurrent clients:

```sh
cd bench && go run . -clients 16 -batch 10 -hot-ratio 0.2
```

It reports transfers/s, statement latency, errors by SQLSTATE, and verifies the ledger
afterwards. See [bench/README.md](bench/README.md) for every knob.
