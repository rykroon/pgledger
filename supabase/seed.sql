-- The worked example from README.md, with fixed UUIDs so queries can be typed by hand.
-- Runs after the migrations, so ledger.* already exists.

INSERT INTO ledger.ledgers (id)
VALUES ('11111111-1111-1111-1111-111111111111');

-- cash: debit-normal, credits may never exceed debits.
INSERT INTO ledger.accounts (id, ledger_id, code, require_debit_balance)
VALUES ('22222222-2222-2222-2222-222222222222',
        '11111111-1111-1111-1111-111111111111', 1, true);

-- revenue: credit-normal, debits may never exceed credits.
INSERT INTO ledger.accounts (id, ledger_id, code, require_credit_balance)
VALUES ('33333333-3333-3333-3333-333333333333',
        '11111111-1111-1111-1111-111111111111', 2, true);

-- A sale: value flows credit -> debit, so cash is debited and revenue credited.
INSERT INTO ledger.transfers (id, ledger_id, debit_account_id, credit_account_id, amount, code)
VALUES ('44444444-4444-4444-4444-444444444444',
        '11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222',
        '33333333-3333-3333-3333-333333333333', 100, 1);
