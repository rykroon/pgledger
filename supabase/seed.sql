-- The worked example from README.md, with fixed UUIDs so queries can be typed by hand.
-- Runs after the migrations, so ledger.* already exists.

-- account_input is (id, ledger, code, require_credit_balance, require_debit_balance,
--                   external_id, external_timestamp)
-- cash: debit-normal, credits may never exceed debits (require_debit_balance).
-- revenue: credit-normal, debits may never exceed credits (require_credit_balance).
SELECT * FROM ledger.create_accounts(ARRAY[
    ROW('22222222-2222-2222-2222-222222222222',
        1, 100, false, true, NULL, NULL)::ledger.account_input,
    ROW('33333333-3333-3333-3333-333333333333',
        1, 400, true, false, NULL, NULL)::ledger.account_input
]);

-- transfer_input is (id, debit_account_id, credit_account_id, amount, code,
--                    balance_debit_account, balance_credit_account,
--                    external_id, external_timestamp)
-- A sale: cash is debited and revenue credited.
SELECT * FROM ledger.create_transfers(ARRAY[
    ROW('44444444-4444-4444-4444-444444444444',
        '22222222-2222-2222-2222-222222222222',
        '33333333-3333-3333-3333-333333333333',
        100, 1, false, false, NULL, NULL)::ledger.transfer_input
]);
