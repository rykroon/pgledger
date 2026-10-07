-- Append-only guarantees: UPDATE/DELETE/TRUNCATE are blocked everywhere, and
-- transfers/account_balances reject direct INSERTs.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(11);

-- Row-level triggers only fire when rows exist, so create some first.
DO $$
BEGIN
    PERFORM ledger.create_account(ledger => 777, code => 100, id => 'aaaaaaaa-0000-0000-0000-000000000001');
    PERFORM ledger.create_account(ledger => 777, code => 200, id => 'aaaaaaaa-0000-0000-0000-000000000002');
    PERFORM ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000001',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000002',
        amount => 50, code => 1,
        id => 'aaaaaaaa-0000-0000-0000-000000000010');
END $$;

SELECT throws_like(
    $$ UPDATE ledger.accounts SET code = 999 WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
    '%append-only%', 'UPDATE on accounts is blocked');
SELECT throws_like(
    $$ DELETE FROM ledger.accounts WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
    '%append-only%', 'DELETE on accounts is blocked');
SELECT throws_like(
    $$ UPDATE ledger.transfers SET code = 999 WHERE id = 'aaaaaaaa-0000-0000-0000-000000000010' $$,
    '%append-only%', 'UPDATE on transfers is blocked');
SELECT throws_like(
    $$ DELETE FROM ledger.transfers WHERE id = 'aaaaaaaa-0000-0000-0000-000000000010' $$,
    '%append-only%', 'DELETE on transfers is blocked');
SELECT throws_like(
    $$ UPDATE ledger.account_balances SET debits_posted = 0 WHERE account_id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
    '%append-only%', 'UPDATE on account_balances is blocked');
SELECT throws_like(
    $$ DELETE FROM ledger.account_balances WHERE account_id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
    '%append-only%', 'DELETE on account_balances is blocked');
SELECT throws_like(
    $$ TRUNCATE ledger.account_balances $$,
    '%append-only%', 'TRUNCATE on account_balances is blocked');
-- accounts/transfers alone would fail the FK cross-reference check first, so
-- truncate all three together to prove the triggers fire.
SELECT throws_like(
    $$ TRUNCATE ledger.accounts, ledger.transfers, ledger.account_balances $$,
    '%append-only%', 'TRUNCATE across the ledger tables is blocked');

SELECT throws_like(
    $$ INSERT INTO ledger.transfers (debit_account_id, credit_account_id, amount, ledger, code)
       VALUES ('aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002', 10, 777, 1) $$,
    '%direct INSERT%', 'direct INSERT into transfers is blocked');
SELECT throws_like(
    $$ INSERT INTO ledger.account_balances (account_id, version, transfer_id, debits_posted, credits_posted)
       VALUES ('aaaaaaaa-0000-0000-0000-000000000001', 99, 'aaaaaaaa-0000-0000-0000-000000000010', 0, 0) $$,
    '%direct INSERT%', 'direct INSERT into account_balances is blocked');

-- accounts have no balance bookkeeping to corrupt, so inserting one directly is fine
SELECT lives_ok(
    $$ INSERT INTO ledger.accounts (ledger, code) VALUES (777, 300) $$,
    'direct INSERT into accounts is allowed');

SELECT * FROM finish();
ROLLBACK;
