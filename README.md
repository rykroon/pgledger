# pgledger

A double-entry ledger for Postgres, inspired by [TigerBeetle](https://tigerbeetle.com/).

Every transfer moves value from a credit account to a debit account, and both sides are
recorded. Nothing is ever updated or deleted — ledgers, accounts, transfers, and balances are all append-only, so the full history stays readable.

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

Create a ledger:

```sql
INSERT INTO ledger.ledgers (id) VALUES ('...ledger-id...');
```

`ledger.ledgers` is intentionally bare. Keep mutable attributes such as a name in your own
table keyed by `ledger_id uuid PRIMARY KEY REFERENCES ledger.ledgers(id)`.

Create accounts. Each account may optionally restrict which side its balance can be on:

```sql
-- cash (code 1 in this example): debit-normal, cannot go below zero
INSERT INTO ledger.accounts (id, ledger_id, code, require_debit_balance)
VALUES ('...cash-id...', '...ledger-id...', 1, true);

-- revenue (code 2): credit-normal, cannot go below zero
INSERT INTO ledger.accounts (id, ledger_id, code, require_credit_balance)
VALUES ('...revenue-id...', '...ledger-id...', 2, true);
```

Post a transfer. Value flows credit -> debit, so recording a sale debits cash and credits
revenue:

```sql
INSERT INTO ledger.transfers (id, ledger_id, debit_account_id, credit_account_id, amount, code)
VALUES ('...transfer-id...', '...ledger-id...', '...cash-id...', '...revenue-id...', 100, 1);
```

A trigger posts the transfer, appends the new running totals to `ledger.account_balances`,
and enforces the balance rules. A multi-row `INSERT` posts every row, and a failure anywhere
rolls back the whole statement. A batch may span ledgers. Rows post in `timestamp` order,
which in practice is the order the statement produced them, but Postgres doesn't guarantee
that order, so don't rely on it.

When one transfer must post before the next, insert them in separate statements in one
transaction. Order changes outcomes: a deposit followed by a withdrawal can succeed where
the reverse fails. Posting across several statements carries a deadlock caveat, covered
under [Concurrency](#concurrency).

A retry is safe with `ON CONFLICT (id) DO NOTHING`: rows that already exist are skipped
and never posted twice.

Read balances:

```sql
SELECT account_id, balance FROM ledger.current_balances WHERE ledger_id = '...ledger-id...';
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

A transfer that would break a rule is rejected and the whole statement rolls back.

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
    ROW('...transfer-id...', '...ledger-id...', '...wallet-id...', '...cash-id...',
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
  the row was inserted. Rows get their own times, even within one statement, but it is not
  unique: two rows can share a microsecond.

Transfers have no total order. Within one account, `ledger.account_balances.version` is the
order of record. Across a ledger there is none, so order a transfer log by `timestamp, id`
for a stable result, bearing in mind that `id` is an arbitrary tiebreak. `timestamp` is
taken while posting holds the account locks, so within one account it follows `version`, but
across accounts it can disagree with the order transactions commit in.

## Concurrency

Posting locks every account the statement touches, in `id` order, until the transaction
ends. Two transactions never post to the same account at once, which is what keeps `version`
gapless and the balance rules honest. Transfers on disjoint accounts post in parallel, and
creating accounts is never blocked.

Because the locks are taken in `id` order, two concurrent statements that touch the same
accounts cannot deadlock, however their rows are ordered. That guarantee covers a single
statement only. A transaction that posts in several statements accumulates locks in statement
order, so two transactions reaching the same accounts through separate statements, in
opposite order, can deadlock and one will be rolled back with SQLSTATE `40P01`.

This matters whenever transfers must be ordered, because ordering them means separate
statements. Lock every account the transaction will touch up front, in `id` order, before
the first `INSERT`:

```sql
SELECT id FROM ledger.accounts
WHERE id IN ('...account-a...', '...account-b...', '...account-c...')
ORDER BY id
FOR NO KEY UPDATE;
```

The locks are held until the transaction ends, so each posting re-requests locks the
transaction already holds and never acquires one out of order.

## Constraints

- Accounts must belong to an existing ledger.
- Transfers cannot cross ledgers, and cannot have the same account on both sides.
- `amount` must be positive. It may be `NULL` (no cap) only on a balancing transfer.
- `code` must be positive.
- `timestamp` is assigned by the ledger; supplying it is rejected (`timestamp_must_not_be_set`
  on a transfer, an error on a ledger or account).
- An account can require a debit balance or a credit balance, but not both.
- A transfer that would break a balance rule is rejected.
- Any `UPDATE`, `DELETE`, or `TRUNCATE` on the ledger tables is rejected.
- Only `ledger.create_transfers()` writes `ledger.transfers` and `ledger.account_balances`.
  It runs as the extension's owner (`SECURITY DEFINER`); any other role that inserts
  directly is rejected, even if it has been granted `INSERT`. Grant your app roles
  `EXECUTE` on the function, not `INSERT` on the tables.

## Benchmark

`bench/` holds a Go program that starts a throwaway `supabase/postgres` container, installs the
extension from the working tree, and posts transfers from concurrent clients:

```sh
cd bench && go run . -clients 16 -batch 10 -hot-ratio 0.2
```

It reports transfers/s, statement latency, errors by SQLSTATE, and verifies the ledger
afterwards. See [bench/README.md](bench/README.md) for every knob.
