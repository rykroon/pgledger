-- create_account / create_accounts: defaults, validation, and constraints.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(15);

DO $$
BEGIN
    PERFORM ledger.create_account(ledger => 777, code => 100, id => 'aaaaaaaa-0000-0000-0000-000000000001');
    PERFORM ledger.create_account(
        ledger => 777, code => 200, id => 'aaaaaaaa-0000-0000-0000-000000000002',
        external_id => 'eeeeeeee-0000-0000-0000-000000000001',
        external_timestamp => '2026-01-01T00:00:00Z');
END $$;

SELECT is(
    (SELECT a.ledger FROM ledger.accounts a WHERE a.id = 'aaaaaaaa-0000-0000-0000-000000000001'),
    777, 'ledger is stored');
SELECT is(
    (SELECT a.code FROM ledger.accounts a WHERE a.id = 'aaaaaaaa-0000-0000-0000-000000000001'),
    100::numeric, 'code is stored');
SELECT ok(
    (SELECT NOT a.require_credit_balance AND NOT a.require_debit_balance
     FROM ledger.accounts a WHERE a.id = 'aaaaaaaa-0000-0000-0000-000000000001'),
    'balance-requirement flags default to false');
SELECT ok(
    (SELECT a.created_at IS NOT NULL
     FROM ledger.accounts a WHERE a.id = 'aaaaaaaa-0000-0000-0000-000000000001'),
    'created_at is set');
SELECT is(
    (SELECT (a.external_id, a.external_timestamp)::text
     FROM ledger.accounts a WHERE a.id = 'aaaaaaaa-0000-0000-0000-000000000002'),
    ('eeeeeeee-0000-0000-0000-000000000001'::uuid, '2026-01-01T00:00:00Z'::timestamptz)::text,
    'external_id and external_timestamp are stored');

SELECT is(
    substring((ledger.create_account(ledger => 777, code => 101)).id::text FROM 15 FOR 1),
    '7', 'generated account ids are uuidv7');

SELECT throws_ok(
    $$ SELECT ledger.create_account(ledger => 0, code => 1) $$,
    '23514', NULL, 'ledger must be positive');
SELECT throws_ok(
    $$ SELECT ledger.create_account(ledger => NULL, code => 1) $$,
    '23502', NULL, 'ledger is required');
SELECT throws_like(
    $$ SELECT ledger.create_account(ledger => 777, code => 0) $$,
    '%positive integer%', 'code must be positive');
SELECT throws_like(
    $$ SELECT ledger.create_account(ledger => 777, code => 1.5) $$,
    '%positive integer%', 'code must be an integer');
SELECT throws_ok(
    $$ SELECT ledger.create_account(ledger => 777, code => 123456) $$,
    '22003', NULL, 'code is limited to 5 digits');
SELECT throws_ok(
    $$ SELECT ledger.create_account(ledger => 777, code => 1,
           require_credit_balance => true, require_debit_balance => true) $$,
    '23514', NULL, 'the two balance-requirement flags are mutually exclusive');
SELECT throws_ok(
    $$ SELECT ledger.create_account(ledger => 777, code => 1, id => 'aaaaaaaa-0000-0000-0000-000000000001') $$,
    '23505', NULL, 'duplicate account ids are rejected');

SELECT is(
    (SELECT count(*) FROM ledger.create_accounts(ARRAY[
        ROW(NULL, 777, 110, NULL, NULL, NULL, NULL)::ledger.account_input,
        ROW(NULL, 777, 111, true, false, NULL, NULL)::ledger.account_input
    ])),
    2::bigint, 'create_accounts creates one account per input');
SELECT is(
    (SELECT count(*) FROM ledger.create_accounts(NULL)),
    0::bigint, 'create_accounts of NULL creates nothing');

SELECT * FROM finish();
ROLLBACK;
