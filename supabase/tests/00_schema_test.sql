-- The objects the extension promises, installed through pg_tle into the schema named in the
-- create_pgledger migration. Every test file rolls back, so the seed data is left as it was.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(14);

SELECT has_extension('ledger', 'pgledger', 'pgledger is installed in ledger');

SELECT has_table('ledger', 'accounts', NULL);
SELECT has_table('ledger', 'transfers', NULL);
SELECT has_table('ledger', 'account_balances', NULL);
SELECT has_view('ledger', 'current_balances', NULL);

SELECT has_function('ledger', 'create_accounts', ARRAY['ledger.account_input[]']);
SELECT has_function('ledger', 'create_transfers', ARRAY['ledger.transfer_input[]']);
SELECT is_definer('ledger', 'create_accounts', ARRAY['ledger.account_input[]']);
SELECT is_definer('ledger', 'create_transfers', ARRAY['ledger.transfer_input[]']);

SELECT col_type_is('ledger', 'accounts', 'ledger', 'integer', 'accounts.ledger is integer');
SELECT col_type_is('ledger', 'accounts', 'code', 'numeric(5,0)', 'accounts.code is numeric(5,0)');
SELECT col_type_is('ledger', 'transfers', 'ledger', 'integer', 'transfers.ledger is integer');
SELECT col_type_is('ledger', 'transfers', 'code', 'numeric(5,0)', 'transfers.code is numeric(5,0)');
SELECT col_type_is('ledger', 'transfers', 'amount', 'numeric(39,0)', 'transfers.amount is numeric(39,0)');

SELECT * FROM finish();
ROLLBACK;
