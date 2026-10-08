-- create_transfer / create_transfers: double-entry posting, validation,
-- balance-requirement flags, and batch atomicity.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(21);

-- A, B: plain accounts on ledger 777. C: ledger 778.
-- R: require_credit_balance (debits must not exceed credits).
-- S: require_debit_balance (credits must not exceed debits).
DO $$
BEGIN
    PERFORM ledger.create_account(ledger => 777, code => 100, id => 'aaaaaaaa-0000-0000-0000-000000000001');
    PERFORM ledger.create_account(ledger => 777, code => 200, id => 'aaaaaaaa-0000-0000-0000-000000000002');
    PERFORM ledger.create_account(ledger => 778, code => 100, id => 'aaaaaaaa-0000-0000-0000-000000000003');
    PERFORM ledger.create_account(ledger => 777, code => 300, id => 'aaaaaaaa-0000-0000-0000-000000000004',
        require_credit_balance => true);
    PERFORM ledger.create_account(ledger => 777, code => 400, id => 'aaaaaaaa-0000-0000-0000-000000000005',
        require_debit_balance => true);
END $$;

SELECT is(
    (SELECT t.amount FROM ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000001',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000002',
        amount => 100, code => 1,
        id => 'aaaaaaaa-0000-0000-0000-000000000010') t),
    100::numeric, 'create_transfer posts the requested amount');
SELECT is(
    (SELECT t.ledger FROM ledger.transfers t WHERE t.id = 'aaaaaaaa-0000-0000-0000-000000000010'),
    777, 'the transfer ledger is derived from the accounts');
SELECT is(
    (SELECT (ab.version, ab.debits_posted, ab.credits_posted)::text
     FROM ledger.account_balances ab
     WHERE ab.account_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
    '(1,100,0)', 'the debit account is debited');
SELECT is(
    (SELECT (ab.version, ab.debits_posted, ab.credits_posted)::text
     FROM ledger.account_balances ab
     WHERE ab.account_id = 'aaaaaaaa-0000-0000-0000-000000000002'),
    '(1,0,100)', 'the credit account is credited');

DO $$
BEGIN
    PERFORM ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000002',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000001',
        amount => 30, code => 1);
END $$;

SELECT is(
    (SELECT (ab.version, ab.debits_posted, ab.credits_posted)::text
     FROM ledger.account_balances ab
     WHERE ab.account_id = 'aaaaaaaa-0000-0000-0000-000000000001'
     ORDER BY ab.version DESC LIMIT 1),
    '(2,100,30)', 'balances accumulate and version increments');
SELECT is(
    (SELECT count(*) FROM ledger.account_balances ab
     WHERE ab.account_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
    2::bigint, 'every transfer appends a balance history row');
SELECT lives_ok(
    $$ SELECT ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000001',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000002',
        amount => 0, code => 1) $$,
    'zero-amount transfers are allowed');

SELECT throws_like(
    $$ SELECT ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000001',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000001',
        amount => 10, code => 1) $$,
    '%itself%', 'transfers between an account and itself are rejected');
SELECT throws_like(
    $$ SELECT ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000001',
        credit_account_id => 'ffffffff-0000-0000-0000-000000000099',
        amount => 10, code => 1) $$,
    '%does not exist%', 'transfers to a missing account are rejected');
SELECT throws_like(
    $$ SELECT ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000001',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000003',
        amount => 10, code => 1) $$,
    '%same ledger%', 'cross-ledger transfers are rejected');
SELECT throws_like(
    $$ SELECT ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000001',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000002',
        amount => -10, code => 1) $$,
    '%non-negative integer%', 'negative amounts are rejected');
SELECT throws_like(
    $$ SELECT ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000001',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000002',
        amount => 10.5, code => 1) $$,
    '%non-negative integer%', 'fractional amounts are rejected');
SELECT throws_like(
    $$ SELECT ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000001',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000002',
        amount => NULL, code => 1) $$,
    '%non-negative integer%', 'NULL amounts are rejected');
SELECT throws_like(
    $$ SELECT ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000001',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000002',
        amount => 10, code => 0) $$,
    '%positive integer%', 'non-positive transfer codes are rejected');

-- R (require_credit_balance) has no credits yet: debiting it must fail.
SELECT throws_ok(
    $$ SELECT ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000004',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000002',
        amount => 10, code => 1) $$,
    '23514', NULL, 'require_credit_balance blocks debits past the credit balance');

-- Fund R with 100 credits, then 60 of it may be debited, but not another 50.
DO $$
BEGIN
    PERFORM ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000002',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000004',
        amount => 100, code => 1);
END $$;
SELECT lives_ok(
    $$ SELECT ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000004',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000002',
        amount => 60, code => 1) $$,
    'require_credit_balance allows debits up to the credit balance');
SELECT throws_ok(
    $$ SELECT ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000004',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000002',
        amount => 50, code => 1) $$,
    '23514', NULL, 'require_credit_balance blocks the transfer that would overdraw');

-- S (require_debit_balance) has no debits yet: crediting it must fail.
SELECT throws_ok(
    $$ SELECT ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000002',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000005',
        amount => 10, code => 1) $$,
    '23514', NULL, 'require_debit_balance blocks credits past the debit balance');

SELECT is(
    (SELECT count(*) FROM ledger.create_transfers(ARRAY[
        ROW(NULL, 'aaaaaaaa-0000-0000-0000-000000000001',
                  'aaaaaaaa-0000-0000-0000-000000000002', 5, 1, NULL, NULL, NULL, NULL)::ledger.transfer_input,
        ROW(NULL, 'aaaaaaaa-0000-0000-0000-000000000002',
                  'aaaaaaaa-0000-0000-0000-000000000001', 5, 1, NULL, NULL, NULL, NULL)::ledger.transfer_input
    ])),
    2::bigint, 'create_transfers posts one transfer per input');

-- A batch where the second input is invalid must not keep the first one.
SELECT throws_like(
    $$ SELECT ledger.create_transfers(ARRAY[
        ROW('aaaaaaaa-0000-0000-0000-000000000020',
            'aaaaaaaa-0000-0000-0000-000000000001',
            'aaaaaaaa-0000-0000-0000-000000000002', 5, 1, NULL, NULL, NULL, NULL)::ledger.transfer_input,
        ROW(NULL, 'aaaaaaaa-0000-0000-0000-000000000001',
                  'aaaaaaaa-0000-0000-0000-000000000003', 5, 1, NULL, NULL, NULL, NULL)::ledger.transfer_input
    ]) $$,
    '%same ledger%', 'a bad input fails the whole batch');
SELECT is(
    (SELECT count(*) FROM ledger.transfers t WHERE t.id = 'aaaaaaaa-0000-0000-0000-000000000020'),
    0::bigint, 'nothing from a failed batch is kept');

SELECT * FROM finish();
ROLLBACK;
