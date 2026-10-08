-- Lookup and query functions.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(14);

DO $$
BEGIN
    PERFORM ledger.create_account(ledger => 777, code => 100, id => 'aaaaaaaa-0000-0000-0000-000000000001'); -- A
    PERFORM ledger.create_account(ledger => 777, code => 200, id => 'aaaaaaaa-0000-0000-0000-000000000002'); -- B
    PERFORM ledger.create_account(ledger => 777, code => 300, id => 'aaaaaaaa-0000-0000-0000-000000000003'); -- no transfers

    PERFORM ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000001',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000002',
        amount => 10, code => 1, id => 'aaaaaaaa-0000-0000-0000-000000000011');
    PERFORM ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000002',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000001',
        amount => 20, code => 1, id => 'aaaaaaaa-0000-0000-0000-000000000012');
    PERFORM ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000001',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000002',
        amount => 5, code => 1, id => 'aaaaaaaa-0000-0000-0000-000000000013');
END $$;

SELECT is(
    (SELECT count(*) FROM ledger.lookup_account('aaaaaaaa-0000-0000-0000-000000000001')),
    1::bigint, 'lookup_account finds an existing account');
SELECT is(
    (SELECT count(*) FROM ledger.lookup_account('ffffffff-0000-0000-0000-000000000099')),
    0::bigint, 'lookup_account of a missing id returns no rows');
SELECT is(
    (SELECT count(*) FROM ledger.lookup_accounts(ARRAY[
        'aaaaaaaa-0000-0000-0000-000000000001',
        'aaaaaaaa-0000-0000-0000-000000000002']::uuid[])),
    2::bigint, 'lookup_accounts finds all requested accounts');
SELECT is(
    (SELECT count(*) FROM ledger.lookup_transfer('aaaaaaaa-0000-0000-0000-000000000011')),
    1::bigint, 'lookup_transfer finds an existing transfer');
SELECT is(
    (SELECT count(*) FROM ledger.lookup_transfers(ARRAY[
        'aaaaaaaa-0000-0000-0000-000000000011',
        'aaaaaaaa-0000-0000-0000-000000000012']::uuid[])),
    2::bigint, 'lookup_transfers finds all requested transfers');

SELECT is(
    (SELECT count(*) FROM ledger.get_account_balance('aaaaaaaa-0000-0000-0000-000000000003')),
    0::bigint, 'get_account_balance of a fresh account returns no rows');
SELECT is(
    (SELECT ab.version FROM ledger.get_account_balance('aaaaaaaa-0000-0000-0000-000000000001') ab),
    3::bigint, 'get_account_balance returns the latest version');
SELECT is(
    (SELECT (ab.debits_posted, ab.credits_posted)::text
     FROM ledger.get_account_balance('aaaaaaaa-0000-0000-0000-000000000001') ab),
    '(15,20)', 'get_account_balance returns the accumulated balance');

SELECT is(
    (SELECT count(*) FROM ledger.get_account_balances('aaaaaaaa-0000-0000-0000-000000000001')),
    3::bigint, 'get_account_balances returns the whole history');
SELECT is(
    (SELECT array_agg(ab.version) FROM ledger.get_account_balances('aaaaaaaa-0000-0000-0000-000000000001') ab),
    ARRAY[3, 2, 1]::bigint[], 'get_account_balances is newest first');
SELECT is(
    (SELECT count(*) FROM ledger.get_account_balances('aaaaaaaa-0000-0000-0000-000000000001', max_rows => 2)),
    2::bigint, 'get_account_balances honors max_rows');
SELECT is(
    (SELECT count(*) FROM ledger.get_account_balances('aaaaaaaa-0000-0000-0000-000000000001',
        created_before => '2000-01-01T00:00:00Z')),
    0::bigint, 'get_account_balances honors the timestamp filters');

SELECT is(
    (SELECT count(*) FROM ledger.get_account_transfers('aaaaaaaa-0000-0000-0000-000000000001')),
    3::bigint, 'get_account_transfers returns transfers on either side');
SELECT is(
    (SELECT count(*) FROM ledger.get_account_transfers('aaaaaaaa-0000-0000-0000-000000000001', max_rows => 1)),
    1::bigint, 'get_account_transfers honors max_rows');

SELECT * FROM finish();
ROLLBACK;
