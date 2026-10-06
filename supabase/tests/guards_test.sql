-- Accounts, transfers and balances are append-only, and only the create functions write them.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(13);

SELECT ledger.create_accounts(ARRAY[
    ROW('d0000000-0000-0000-0000-000000000001', 904, 1, NULL, NULL, false, false),
    ROW('d0000000-0000-0000-0000-000000000002', 904, 1, NULL, NULL, false, false)
]::ledger.account_input[]);
SELECT ledger.create_transfers(ARRAY[
    ROW('e0000000-0000-0000-0000-000000000001', 904,
        'd0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000002',
        1, 1, NULL, NULL, NULL, NULL)
]::ledger.transfer_input[]);

SELECT throws_like($$UPDATE ledger.accounts SET code = 2$$,
                   '%ledger.accounts is append-only: UPDATE is not allowed');
SELECT throws_like($$DELETE FROM ledger.accounts$$,
                   '%ledger.accounts is append-only: DELETE is not allowed');
SELECT throws_like($$TRUNCATE ledger.accounts$$,
                   '%ledger.accounts is append-only: TRUNCATE is not allowed');
SELECT throws_like($$UPDATE ledger.transfers SET amount = 2$$,
                   '%ledger.transfers is append-only: UPDATE is not allowed');
SELECT throws_like($$DELETE FROM ledger.transfers$$,
                   '%ledger.transfers is append-only: DELETE is not allowed');
SELECT throws_like($$TRUNCATE ledger.transfers$$,
                   '%ledger.transfers is append-only: TRUNCATE is not allowed');
SELECT throws_like($$UPDATE ledger.account_balances SET version = version + 1$$,
                   '%ledger.account_balances is append-only: UPDATE is not allowed');
SELECT throws_like($$DELETE FROM ledger.account_balances$$,
                   '%ledger.account_balances is append-only: DELETE is not allowed');
SELECT throws_like($$TRUNCATE ledger.account_balances$$,
                   '%ledger.account_balances is append-only: TRUNCATE is not allowed');

-- A role that isn't the owner is rejected even with INSERT granted, but may still go
-- through the functions.
GRANT USAGE ON SCHEMA ledger TO authenticated;
GRANT INSERT ON ledger.accounts, ledger.transfers, ledger.account_balances TO authenticated;
SET LOCAL ROLE authenticated;

SELECT throws_like(
    $$INSERT INTO ledger.accounts
      VALUES ('d0000000-0000-0000-0000-000000000003', now(), 904, 1, NULL, NULL, false, false)$$,
    '%ledger.accounts is written by ledger.create_accounts(); INSERTing into it directly is not allowed'
);
SELECT throws_like(
    $$INSERT INTO ledger.transfers
      VALUES ('e0000000-0000-0000-0000-000000000002', now(), 904,
              'd0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000002',
              1, 1, NULL, NULL, false, false)$$,
    '%ledger.transfers is written by ledger.create_transfers(); INSERTing into it directly is not allowed'
);
SELECT throws_like(
    $$INSERT INTO ledger.account_balances
      VALUES ('d0000000-0000-0000-0000-000000000001', 99, 'e0000000-0000-0000-0000-000000000001', 0, 0)$$,
    '%ledger.account_balances is written by ledger.create_transfers(); INSERTing into it directly is not allowed'
);
SELECT results_eq(
    $$SELECT code FROM ledger.create_accounts(ARRAY[
        ROW('d0000000-0000-0000-0000-000000000004', 904, 1, NULL, NULL, false, false)
    ]::ledger.account_input[])$$,
    $$VALUES ('ok')$$,
    'a non-owner can create accounts through create_accounts()'
);

RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
