-- balance_debit_account / balance_credit_account: amount is a maximum, capped
-- so the respective account's balance is not pushed past zero.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(6);

DO $$
BEGIN
    PERFORM ledger.create_account(ledger => 777, code => 100, id => 'aaaaaaaa-0000-0000-0000-000000000001'); -- A
    PERFORM ledger.create_account(ledger => 777, code => 200, id => 'aaaaaaaa-0000-0000-0000-000000000002'); -- B
    PERFORM ledger.create_account(ledger => 777, code => 100, id => 'aaaaaaaa-0000-0000-0000-000000000003'); -- C
    PERFORM ledger.create_account(ledger => 777, code => 200, id => 'aaaaaaaa-0000-0000-0000-000000000004'); -- D
    PERFORM ledger.create_account(ledger => 777, code => 100, id => 'aaaaaaaa-0000-0000-0000-000000000005'); -- E
    PERFORM ledger.create_account(ledger => 777, code => 200, id => 'aaaaaaaa-0000-0000-0000-000000000006'); -- F
    PERFORM ledger.create_account(ledger => 777, code => 300, id => 'aaaaaaaa-0000-0000-0000-000000000007',
        require_credit_balance => true);                                                                    -- G

    -- A gets a net credit balance of 100.
    PERFORM ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000002',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000001',
        amount => 100, code => 1);
    -- C gets a net debit balance of 80.
    PERFORM ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000003',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000004',
        amount => 80, code => 1);
    -- E gets a net credit balance of 30 from F (so F has a net debit of 30).
    PERFORM ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000006',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000005',
        amount => 30, code => 1);
    -- G (require_credit_balance) gets a credit balance of 40.
    PERFORM ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000002',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000007',
        amount => 40, code => 1);
END $$;

SELECT is(
    (SELECT t.amount FROM ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000001',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000002',
        amount => 150, code => 1,
        balance_debit_account => true) t),
    100::numeric, 'balance_debit_account caps the amount at the debit account''s credit balance');
SELECT is(
    (SELECT (ab.debits_posted, ab.credits_posted)::text
     FROM ledger.account_balances ab
     WHERE ab.account_id = 'aaaaaaaa-0000-0000-0000-000000000001'
     ORDER BY ab.version DESC LIMIT 1),
    '(100,100)', 'the balancing transfer zeroes the debit account''s net balance');
SELECT is(
    (SELECT t.amount FROM ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000001',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000002',
        amount => 50, code => 1,
        balance_debit_account => true) t),
    0::numeric, 'a balancing debit with nothing available posts 0');
SELECT is(
    (SELECT t.amount FROM ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000004',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000003',
        amount => 200, code => 1,
        balance_credit_account => true) t),
    80::numeric, 'balance_credit_account caps the amount at the credit account''s debit balance');
SELECT is(
    (SELECT t.amount FROM ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000005',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000006',
        amount => 100, code => 1,
        balance_debit_account => true,
        balance_credit_account => true) t),
    30::numeric, 'both balancing flags apply the smaller cap');
SELECT is(
    (SELECT t.amount FROM ledger.create_transfer(
        debit_account_id => 'aaaaaaaa-0000-0000-0000-000000000007',
        credit_account_id => 'aaaaaaaa-0000-0000-0000-000000000002',
        amount => 500, code => 1,
        balance_debit_account => true) t),
    40::numeric, 'a balancing debit satisfies require_credit_balance by construction');

SELECT * FROM finish();
ROLLBACK;
