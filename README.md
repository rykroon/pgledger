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

Create accounts with `ledger.create_accounts()`, which takes an array of `ledger.accounts`
rows with `timestamp` left `NULL`. Each account may optionally restrict which side its
balance can be on. The fields are `id, ledger, code, external_id, external_timestamp,
require_credit_balance, require_debit_balance, timestamp`:

```sql
SELECT * FROM ledger.create_accounts(ARRAY[
    -- cash (code 1 in this example): debit-normal, cannot go below zero
    ROW('...cash-id...', 1, 1, NULL, NULL, false, true, NULL)::ledger.accounts,
    -- revenue (code 2): credit-normal, cannot go below zero
    ROW('...revenue-id...', 1, 2, NULL, NULL, true, false, NULL)::ledger.accounts
]);
```

It returns one `(ord, account_id, code)` row per input, in input order. `code` is `ok` or the
first failed check: `timestamp_must_not_be_set`, `id_not_set`, `ledger_invalid`,
`code_invalid`, `flags_are_mutually_exclusive` (both balance requirements set), or
`id_already_exists`. A rejected row doesn't stop the others from being created, and a `NULL`
balance requirement counts as `false`. When an id appears more than once in a batch, only
its first valid copy is created. A retry is safe: accounts that already exist come back as
`id_already_exists`.

Post transfers with `ledger.create_transfers()`, which takes an array of `ledger.transfers`
rows with `timestamp` left `NULL`. The fields are `id, ledger, debit_account_id,
credit_account_id, amount, code, external_id, external_timestamp, balancing_debit,
balancing_credit, timestamp`. Value flows credit -> debit, so recording a sale debits cash
and credits revenue:

```sql
SELECT * FROM ledger.create_transfers(ARRAY[
    ROW('...transfer-id...', 1, '...cash-id...', '...revenue-id...',
        100, 1, NULL, NULL, false, false, NULL)::ledger.transfers
]);
```

It returns one `(ord, transfer_id, code)` row per input, in input order. `code` is `ok` or the
first failed check:

- the row's own values: `timestamp_must_not_be_set`, `id_not_set`, `ledger_invalid`,
  `amount_must_be_positive`, `code_invalid`, `accounts_must_be_different`
- lookups: `id_already_exists`, `debit_account_not_found`, `credit_account_not_found`,
  `debit_account_ledger_mismatch`, `credit_account_ledger_mismatch`
- balances: `overflows_debits_posted`, `overflows_credits_posted` (the transfer would push an
  account's running total past 2^128 − 1), `exceeds_credits`, `exceeds_debits`

Each accepted transfer is inserted into `ledger.transfers` with two new running-total rows in
`ledger.account_balances`. A rejected row doesn't stop the others from posting, and a `NULL`
balancing flag counts as `false`. A batch may span ledgers.

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
account's postings from 1 and is their order; join `ledger.transfers` for timestamps:

```sql
SELECT ab.version, ab.debits_posted - ab.credits_posted AS balance, t.timestamp
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

`balancing_debit` and `balancing_credit` on `ledger.transfers` work like TigerBeetle's
flags of the same names: they make `amount` a maximum rather than an exact amount.

- `balancing_debit`: move no more than keeps the debit account's debits from exceeding its
  credits.
- `balancing_credit`: move no more than keeps the credit account's credits from exceeding
  its debits.
- Both: move the smaller of the two.

With either flag, a `NULL` amount means no cap. To pay out whatever a customer's
credit-normal wallet holds:

```sql
SELECT * FROM ledger.create_transfers(ARRAY[
    ROW('...transfer-id...', 1, '...wallet-id...', '...cash-id...',
        NULL, 3, NULL, NULL, true, false, NULL)::ledger.transfers
]);
```

The amount is worked out while posting holds the account locks, against the balance left
by any earlier rows in the same batch, so there is no read-then-write race to manage. The
clamp applies whatever balance rules the accounts have, and those rules are still checked
afterwards. `ledger.transfers.amount` records what actually moved, and the stored
`balancing_debit` and `balancing_credit` columns record that the transfer was a balancing one.
If nothing would move, the row is rejected: with `exceeds_credits` if the debit side is
balancing and already at zero, and `exceeds_debits` otherwise.

## Your data on accounts and transfers

Accounts and transfers both carry three fields that belong to you. The ledger stores
them but never interprets them:

- `code` (required, positive integer): a category you define, such as an account type from
  your chart of accounts or a transfer kind (sale, refund, fee). It doesn't reference any
  table.
- `external_id` (optional `uuid`): links the row to something in your system, e.g. a
  customer, an order, or a group of related transfers.
- `external_timestamp` (optional `timestamptz`): a time of your own, such as an effective
  date or the original time of an imported record. It doesn't change the order balances
  are applied in. `timestamp` is always set by the ledger, never by you, to the clock time
  the row was inserted. Rows get their own times, even within one batch, but it is not
  unique: two rows can share a microsecond.

Transfers have no total order. Within one account, `ledger.account_balances.version` is the
order of record. Across a ledger there is none, so order a transfer log by `timestamp, id`
for a stable result, bearing in mind that `id` is an arbitrary tiebreak. `timestamp` is
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
- `amount` must be a positive whole number no greater than 2^128 − 1, TigerBeetle's u128
  limit, and each account's `debits_posted` and `credits_posted` are capped there too. It may
  be `NULL` (no cap) only on a balancing transfer.
- `code` must be between 1 and 65535 (TigerBeetle's u16).
- `timestamp` is assigned by the ledger; supplying it is rejected (`timestamp_must_not_be_set`).
- An account can require a debit balance or a credit balance, but not both.
- A transfer that would break a balance rule is rejected.
- Any `UPDATE`, `DELETE`, or `TRUNCATE` on the ledger tables is rejected.
- Only `ledger.create_accounts()` writes `ledger.accounts`, and only
  `ledger.create_transfers()` writes `ledger.transfers` and `ledger.account_balances`.
  Both run as the extension's owner (`SECURITY DEFINER`); any other role that inserts
  directly is rejected, even if it has been granted `INSERT`. Grant your app roles
  `EXECUTE` on the functions, not `INSERT` on the tables.

## Benchmark

`bench/` holds a Go program that starts a throwaway `supabase/postgres` container, installs the
extension from the working tree, and posts transfers from concurrent clients:

```sh
cd bench && go run . -clients 16 -batch 10 -hot-ratio 0.2
```

It reports transfers/s, statement latency, errors by SQLSTATE, and verifies the ledger
afterwards. See [bench/README.md](bench/README.md) for every knob.
