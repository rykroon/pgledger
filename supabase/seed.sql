-- The worked example from README.md, with fixed UUIDs so queries can be typed by hand.
-- Runs after the migrations, so ledger.* already exists.

INSERT INTO ledger.ledgers (id)
VALUES ('11111111-1111-1111-1111-111111111111');

-- cash: debit-normal, credits may never exceed debits.
-- revenue: credit-normal, debits may never exceed credits.
-- Direct INSERTs into ledger.accounts are rejected; accounts go through create_accounts().
SELECT * FROM ledger.create_accounts(ARRAY[
    ROW('22222222-2222-2222-2222-222222222222',
        '11111111-1111-1111-1111-111111111111', 1, NULL, NULL, false, true, NULL)::ledger.accounts,
    ROW('33333333-3333-3333-3333-333333333333',
        '11111111-1111-1111-1111-111111111111', 2, NULL, NULL, true, false, NULL)::ledger.accounts
]);

-- A sale: value flows credit -> debit, so cash is debited and revenue credited.
-- Direct INSERTs into ledger.transfers are rejected; posting goes through create_transfers().
SELECT * FROM ledger.create_transfers(ARRAY[
    ROW('44444444-4444-4444-4444-444444444444',
        '11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222',
        '33333333-3333-3333-3333-333333333333', 100, 1, NULL, NULL, NULL, NULL, NULL)::ledger.transfers
]);
