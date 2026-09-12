# pgledger

A double-entry ledger for Postgres, packaged as a Trusted Language Extension (TLE).
Inspired by [TigerBeetle](https://tigerbeetle.com/).

Every transfer moves value from a credit account to a debit account, and both sides are
recorded. Nothing is ever updated or deleted — accounts, transfers, and balances are all
append-only, so the full history stays readable.

## Install

```sql
CREATE EXTENSION pgledger;
```

This creates a `ledger` schema holding the extension's objects.

## Usage

Every ledger has one **issuer** (an account with a `NULL` external_user_id) whose balance
is the outstanding supply, plus one account per user. Ids are UUIDv7 values supplied by
the application.

Create a ledger's accounts:

```sql
-- the issuer: its supply cannot go negative
INSERT INTO ledger.accounts (id, ledger_id, external_user_id, require_credit_balance)
VALUES ('...issuer-id...', '...ledger-id...', NULL, true);

-- a user: cannot be overdrawn
INSERT INTO ledger.accounts (id, ledger_id, external_user_id, require_debit_balance)
VALUES ('...user-id...', '...ledger-id...', '...external-user-id...', true);
```

Post a transfer. Value flows credit -> debit, so granting a user funds debits the user
and credits the issuer:

```sql
INSERT INTO ledger.transfers (id, ledger_id, debit_account_id, credit_account_id, amount)
VALUES ('...transfer-id...', '...ledger-id...', '...user-id...', '...issuer-id...', 100);
```

A trigger posts the transfer, appends the new running totals to `ledger.account_balances`,
and enforces the overdraft rules. Batch transfers by posting them as a single `INSERT` —
they are applied in `id` order.

Read balances:

```sql
SELECT account_id, balance FROM ledger.current_balances WHERE ledger_id = '...ledger-id...';
```

`balance` is debits minus credits, so users read positive and the issuer reads negative.
A ledger always sums to zero.

## Constraints

- Transfers cannot cross ledgers, and cannot have the same account on both sides.
- `amount` must be positive.
- An account can require a debit balance or a credit balance, but not both.
- A transfer that would break an overdraft rule raises SQLSTATE `LG001`.
- Any `UPDATE`, `DELETE`, or `TRUNCATE` on the ledger tables raises
  `restrict_violation`.
