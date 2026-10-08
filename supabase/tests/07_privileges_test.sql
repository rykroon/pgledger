-- Privileges: an ordinary role with only USAGE on the schema can create accounts and
-- transfers through the SECURITY DEFINER API functions, but cannot call the internal
-- post_transfer(), which skips account locking.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(5);

CREATE ROLE pgledger_test_app NOLOGIN;
GRANT USAGE ON SCHEMA ledger TO pgledger_test_app;
GRANT pgledger_test_app TO current_user;

-- pgTAP's bookkeeping belongs to the test owner, so the calls run as the app role inside
-- a DO block and record their outcomes in transaction-local settings for the asserts below.
DO $$
BEGIN
    SET LOCAL ROLE pgledger_test_app;

    PERFORM ledger.create_account(ledger => 777, code => 100, id => 'bbbbbbbb-0000-0000-0000-000000000001');
    PERFORM set_config('test.account', 'ok', true);

    PERFORM ledger.create_accounts(ARRAY[
        ROW('bbbbbbbb-0000-0000-0000-000000000002', 777, 200, false, false, NULL, NULL)::ledger.account_input]);
    PERFORM set_config('test.accounts', 'ok', true);

    PERFORM ledger.create_transfer(
        debit_account_id => 'bbbbbbbb-0000-0000-0000-000000000001',
        credit_account_id => 'bbbbbbbb-0000-0000-0000-000000000002',
        amount => 10, code => 1);
    PERFORM set_config('test.single', 'ok', true);

    PERFORM ledger.create_transfers(ARRAY[
        ROW(NULL, 'bbbbbbbb-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000001',
            5, 1, false, false, NULL, NULL)::ledger.transfer_input]);
    PERFORM set_config('test.batch', 'ok', true);

    BEGIN
        PERFORM ledger.post_transfer(
            'bbbbbbbb-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000002',
            1, 1, NULL, false, false, NULL, NULL);
        PERFORM set_config('test.internal', 'allowed', true);
    EXCEPTION WHEN insufficient_privilege THEN
        PERFORM set_config('test.internal', 'denied', true);
    END;

    RESET ROLE;
END $$;

SELECT is(current_setting('test.account', true), 'ok',
    'an unprivileged role can call create_account');
SELECT is(current_setting('test.accounts', true), 'ok',
    'an unprivileged role can call create_accounts');
SELECT is(current_setting('test.single', true), 'ok',
    'an unprivileged role can call create_transfer');
SELECT is(current_setting('test.batch', true), 'ok',
    'an unprivileged role can call create_transfers');
SELECT is(current_setting('test.internal', true), 'denied',
    'an unprivileged role cannot call post_transfer');

SELECT * FROM finish();
ROLLBACK;
