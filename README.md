# pgledger

A double-entry ledger for Postgres, packaged as a Trusted Language Extension (TLE).
Inspired by [TigerBeetle](https://tigerbeetle.com/).

Every transfer moves value from a credit account to a debit account, and both sides are
recorded. Nothing is ever updated or deleted — ledgers, accounts, transfers, and balances are all append-only, so the full history stays readable.

## Install

```sql
CREATE EXTENSION pgledger;
```

This creates a `ledger` schema holding the extension's objects.

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
and enforces the balance rules. Post a batch as a single multi-row `INSERT`: the rows are
applied in the order you wrote them, each posted in full before the next, and a failure
anywhere rolls back the whole statement. A batch may span ledgers.

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

A transfer that would break a rule is rejected with SQLSTATE `LG001`.

## Draining an account

To transfer an account's entire balance, lock the accounts, read the balance, and post
that amount in one transaction. For example, to pay out whatever a customer's
credit-normal wallet holds:

```sql
BEGIN;

-- Lock both accounts of the transfer, in id order, as posting does.
SELECT id FROM ledger.accounts
WHERE id IN ('...wallet-id...', '...cash-id...')
ORDER BY id
FOR NO KEY UPDATE;

SELECT -balance AS amount FROM ledger.current_balances WHERE account_id = '...wallet-id...';

-- If amount > 0:
INSERT INTO ledger.transfers (id, ledger_id, debit_account_id, credit_account_id, amount, code)
VALUES ('...transfer-id...', '...ledger-id...', '...wallet-id...', '...cash-id...', :amount, 3);

COMMIT;
```

Lock `ledger.accounts` rows, which is what posting waits on. Locking `ledger.account_balances`
rows doesn't block other postings, and an account that has never been posted to has no
balance rows to lock. Lock both accounts, not just the one being drained: taking one first
and the other when the transfer posts can deadlock with a concurrent posting.

Use `READ COMMITTED`. Under `REPEATABLE READ` or `SERIALIZABLE` the balance you read can be
older than the lock; the insert then fails with a unique violation and the transaction must
be retried.

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
  are applied in. `created_at` is always set by the ledger to the time of the inserting
  transaction, never by you. Transfers posted in one transaction share it.

Transfers also carry `seq`, assigned by the ledger as each row is inserted. It is what
orders a multi-row `INSERT`, and a tiebreak for listings that share `created_at`. It is
allocation order, not commit order: a lower `seq` can commit later, so don't use it as a
change cursor. For `INSERT ... SELECT`, add an `ORDER BY` to the `SELECT` to control the order. Within one account, `ledger.account_balances.version` is the order of record.

## Concurrency

Posting locks every account the statement touches, in `id` order, until the transaction
ends. Two transactions never post to the same account at once, which is what keeps `version`
gapless and the balance rules honest. Transfers on disjoint accounts post in parallel, and
creating accounts is never blocked.

Because the locks are taken in `id` order, two concurrent statements that touch the same
accounts cannot deadlock, however their rows are ordered. That holds within a single
statement. A transaction that posts in several statements accumulates locks in statement
order, so two transactions reaching the same accounts through separate statements, in
opposite order, can deadlock and one will be rolled back with SQLSTATE `40P01`. Post
everything a transaction needs in one `INSERT` to avoid it.

## Constraints

- Accounts must belong to an existing ledger.
- Transfers cannot cross ledgers, and cannot have the same account on both sides.
- `amount` must be positive.
- `code` must be positive.
- Supplying `created_at` raises SQLSTATE `428C9` (`generated_always`).
- An account can require a debit balance or a credit balance, but not both.
- A transfer that would break a balance rule raises SQLSTATE `LG001`.
- Any `UPDATE`, `DELETE`, or `TRUNCATE` on the ledger tables raises
  `restrict_violation`, and so does inserting into `ledger.account_balances` directly.
