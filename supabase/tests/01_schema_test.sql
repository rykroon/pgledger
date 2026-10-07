-- Schema shape: tables, key column types, and the public functions.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(22);

SELECT has_table('ledger'::name, 'accounts'::name);
SELECT has_table('ledger'::name, 'transfers'::name);
SELECT has_table('ledger'::name, 'account_balances'::name);

SELECT col_type_is('ledger', 'accounts', 'ledger', 'integer', 'accounts.ledger is an integer');
SELECT col_type_is('ledger', 'accounts', 'code', 'numeric(5,0)', 'accounts.code is numeric(5,0)');
SELECT col_type_is('ledger', 'transfers', 'amount', 'numeric(39,0)', 'transfers.amount is numeric(39,0)');
SELECT col_type_is('ledger', 'account_balances', 'version', 'bigint', 'account_balances.version is a bigint');

SELECT col_is_pk('ledger', 'account_balances', ARRAY['account_id', 'version']);

SELECT has_function('ledger'::name, 'uuidv7'::name);
SELECT has_function('ledger'::name, 'lock_account'::name);
SELECT has_function('ledger'::name, 'create_account'::name);
SELECT has_function('ledger'::name, 'create_accounts'::name);
SELECT has_function('ledger'::name, 'create_transfer'::name);
SELECT has_function('ledger'::name, 'create_transfers'::name);
SELECT has_function('ledger'::name, 'lookup_account'::name);
SELECT has_function('ledger'::name, 'lookup_accounts'::name);
SELECT has_function('ledger'::name, 'lookup_transfer'::name);
SELECT has_function('ledger'::name, 'lookup_transfers'::name);
SELECT has_function('ledger'::name, 'get_account_balance'::name);
SELECT has_function('ledger'::name, 'get_account_balances'::name);
SELECT has_function('ledger'::name, 'get_account_transfers'::name);

SELECT is(substring(ledger.uuidv7()::text FROM 15 FOR 1), '7', 'uuidv7() generates version-7 uuids');

SELECT * FROM finish();
ROLLBACK;
