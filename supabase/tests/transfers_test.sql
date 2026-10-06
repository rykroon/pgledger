-- create_transfers(): per-row result codes, balance rules, balancing transfers and the
-- running totals they leave behind. Accounts here live in ledgers 902 and 903.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(18);

-- a(n) is the nth test account id, t(n) the nth transfer id.
CREATE FUNCTION pg_temp.a(n integer) RETURNS uuid LANGUAGE sql AS $$
    SELECT format('b0000000-0000-0000-0000-%s', lpad(n::text, 12, '0'))::uuid
$$;
CREATE FUNCTION pg_temp.t(n integer) RETURNS uuid LANGUAGE sql AS $$
    SELECT format('c0000000-0000-0000-0000-%s', lpad(n::text, 12, '0'))::uuid
$$;

CREATE FUNCTION pg_temp.tr(id uuid, debit_account_id uuid, credit_account_id uuid,
                           amount numeric,
                           balance_debit_account  boolean DEFAULT NULL,
                           balance_credit_account boolean DEFAULT NULL,
                           ledger integer DEFAULT 902, code numeric DEFAULT 1)
RETURNS ledger.transfer_input LANGUAGE sql AS $$
    SELECT ROW(id, ledger, debit_account_id, credit_account_id, amount, code, NULL, NULL,
               balance_debit_account, balance_credit_account)::ledger.transfer_input
$$;

-- 1, 2, 5..8, 10..12: no balance rule. 3: credits may not exceed debits. 4: debits may not
-- exceed credits. 9: another ledger.
SELECT results_eq(
    $$SELECT code FROM ledger.create_accounts(ARRAY[
        ROW(pg_temp.a(1),  902, 1, NULL, NULL, false, false),
        ROW(pg_temp.a(2),  902, 1, NULL, NULL, false, false),
        ROW(pg_temp.a(3),  902, 1, NULL, NULL, false, true),
        ROW(pg_temp.a(4),  902, 1, NULL, NULL, true,  false),
        ROW(pg_temp.a(5),  902, 1, NULL, NULL, false, false),
        ROW(pg_temp.a(6),  902, 1, NULL, NULL, false, false),
        ROW(pg_temp.a(7),  902, 1, NULL, NULL, false, false),
        ROW(pg_temp.a(8),  902, 1, NULL, NULL, false, false),
        ROW(pg_temp.a(9),  903, 1, NULL, NULL, false, false),
        ROW(pg_temp.a(10), 902, 1, NULL, NULL, false, false),
        ROW(pg_temp.a(11), 902, 1, NULL, NULL, false, false)
    ]::ledger.account_input[])$$,
    $$SELECT 'ok' FROM generate_series(1, 11)$$,
    'setup: accounts created'
);

-- Phase 1: the row's own values, then its lookups.
SELECT results_eq(
    $$SELECT ord, code FROM ledger.create_transfers(ARRAY[
        pg_temp.tr(pg_temp.t(1),  pg_temp.a(1), pg_temp.a(2), 10),
        pg_temp.tr(NULL,          pg_temp.a(1), pg_temp.a(2), 10),
        pg_temp.tr(pg_temp.t(3),  pg_temp.a(1), pg_temp.a(2), 10, ledger => 0),
        pg_temp.tr(pg_temp.t(4),  pg_temp.a(1), pg_temp.a(2), 0),
        pg_temp.tr(pg_temp.t(5),  pg_temp.a(1), pg_temp.a(2), -1),
        pg_temp.tr(pg_temp.t(6),  pg_temp.a(1), pg_temp.a(2), 1.5),
        pg_temp.tr(pg_temp.t(7),  pg_temp.a(1), pg_temp.a(2), NULL),
        pg_temp.tr(pg_temp.t(8),  pg_temp.a(1), pg_temp.a(2), 1e39),
        pg_temp.tr(pg_temp.t(9),  pg_temp.a(1), pg_temp.a(2), 10, code => 0),
        pg_temp.tr(pg_temp.t(10), pg_temp.a(1), pg_temp.a(1), 10),
        pg_temp.tr(pg_temp.t(11), pg_temp.a(99), pg_temp.a(2), 10),
        pg_temp.tr(pg_temp.t(12), pg_temp.a(1), pg_temp.a(99), 10),
        pg_temp.tr(pg_temp.t(13), pg_temp.a(9), pg_temp.a(2), 10),
        pg_temp.tr(pg_temp.t(14), pg_temp.a(1), pg_temp.a(9), 10),
        pg_temp.tr(pg_temp.t(15), pg_temp.a(2), pg_temp.a(1), 4),
        pg_temp.tr(pg_temp.t(1),  pg_temp.a(1), pg_temp.a(2), 10)
    ])$$,
    $$VALUES (1, 'ok'), (2, 'id_not_set'), (3, 'ledger_invalid'),
             (4, 'amount_must_be_positive'), (5, 'amount_must_be_positive'),
             (6, 'amount_must_be_positive'), (7, 'amount_must_be_positive'),
             (8, 'amount_must_be_positive'), (9, 'code_invalid'),
             (10, 'accounts_must_be_different'), (11, 'debit_account_not_found'),
             (12, 'credit_account_not_found'), (13, 'debit_account_ledger_mismatch'),
             (14, 'credit_account_ledger_mismatch'), (15, 'ok'), (16, 'id_already_exists')$$,
    'each row gets the first failed check; a repeated id posts once'
);

SELECT results_eq(
    $$SELECT id, amount FROM ledger.transfers WHERE ledger = 902 ORDER BY id$$,
    $$VALUES (pg_temp.t(1), 10::numeric), (pg_temp.t(15), 4::numeric)$$,
    'only ok rows are written'
);

SELECT results_eq(
    $$SELECT account_id, version, debits_posted, credits_posted, balance
      FROM ledger.current_balances WHERE account_id IN (pg_temp.a(1), pg_temp.a(2))
      ORDER BY account_id$$,
    $$VALUES (pg_temp.a(1), 2::bigint, 10::numeric, 4::numeric, 6::numeric),
             (pg_temp.a(2), 2::bigint,  4::numeric, 10::numeric, -6::numeric)$$,
    'current_balances has the running totals'
);

SELECT results_eq(
    $$SELECT account_id, version, transfer_id FROM ledger.account_balances
      WHERE account_id = pg_temp.a(1) ORDER BY version$$,
    $$VALUES (pg_temp.a(1), 1::bigint, pg_temp.t(1)), (pg_temp.a(1), 2::bigint, pg_temp.t(15))$$,
    'each posting appends a balance row with the next version'
);

SELECT results_eq(
    $$SELECT code FROM ledger.create_transfers(ARRAY[
        pg_temp.tr(pg_temp.t(1), pg_temp.a(1), pg_temp.a(2), 10)])$$,
    $$VALUES ('id_already_exists')$$,
    'an id already in transfers is rejected'
);

-- Balance rules. 3 may not have more credits than debits, 4 more debits than credits.
SELECT results_eq(
    $$SELECT ord, code FROM ledger.create_transfers(ARRAY[
        pg_temp.tr(pg_temp.t(20), pg_temp.a(1), pg_temp.a(3), 1),
        pg_temp.tr(pg_temp.t(21), pg_temp.a(4), pg_temp.a(1), 1),
        pg_temp.tr(pg_temp.t(22), pg_temp.a(3), pg_temp.a(1), 10),
        pg_temp.tr(pg_temp.t(23), pg_temp.a(1), pg_temp.a(3), 15),
        pg_temp.tr(pg_temp.t(24), pg_temp.a(1), pg_temp.a(3), 10)
    ])$$,
    $$VALUES (1, 'exceeds_debits'), (2, 'exceeds_credits'), (3, 'ok'),
             (4, 'exceeds_debits'), (5, 'ok')$$,
    'balance rules see earlier rows in the batch, and a rejected row changes nothing'
);

SELECT results_eq(
    $$SELECT debits_posted, credits_posted FROM ledger.current_balances
      WHERE account_id = pg_temp.a(3)$$,
    $$VALUES (10::numeric, 10::numeric)$$,
    'an account may be brought exactly to its limit'
);

SELECT results_eq(
    $$SELECT ord, code FROM ledger.create_transfers(ARRAY[
        pg_temp.tr(pg_temp.t(30), pg_temp.a(4), pg_temp.a(1), 1),
        pg_temp.tr(pg_temp.t(30), pg_temp.a(1), pg_temp.a(2), 1),
        pg_temp.tr(pg_temp.t(30), pg_temp.a(1), pg_temp.a(2), 1)
    ])$$,
    $$VALUES (1, 'exceeds_credits'), (2, 'ok'), (3, 'id_already_exists')$$,
    'a repeated id posts once, and a copy rejected by a balance rule does not count'
);

-- Balancing transfers. Give 5 a debit surplus of 30 and 6 a credit surplus of 30.
SELECT results_eq(
    $$SELECT code FROM ledger.create_transfers(ARRAY[
        pg_temp.tr(pg_temp.t(40), pg_temp.a(5), pg_temp.a(6), 30)])$$,
    $$VALUES ('ok')$$,
    'setup: 5 debited, 6 credited'
);

SELECT results_eq(
    $$SELECT ord, code FROM ledger.create_transfers(ARRAY[
        pg_temp.tr(pg_temp.t(41), pg_temp.a(7), pg_temp.a(5), 100, balance_credit_account => true),
        pg_temp.tr(pg_temp.t(42), pg_temp.a(7), pg_temp.a(5), 100, balance_credit_account => true),
        pg_temp.tr(pg_temp.t(43), pg_temp.a(6), pg_temp.a(8), NULL, balance_debit_account => true),
        pg_temp.tr(pg_temp.t(44), pg_temp.a(6), pg_temp.a(8), NULL, balance_debit_account => true)
    ])$$,
    $$VALUES (1, 'ok'), (2, 'exceeds_debits'), (3, 'ok'), (4, 'exceeds_credits')$$,
    'a balancing transfer with nothing left to move is rejected'
);

SELECT results_eq(
    $$SELECT id, amount, balance_debit_account, balance_credit_account
      FROM ledger.transfers WHERE id IN (pg_temp.t(41), pg_temp.t(43)) ORDER BY id$$,
    $$VALUES (pg_temp.t(41), 30::numeric, false, true),
             (pg_temp.t(43), 30::numeric, true, false)$$,
    'amount is capped by the balance (NULL is no cap) and the flag is stored'
);

SELECT results_eq(
    $$SELECT balance FROM ledger.current_balances
      WHERE account_id IN (pg_temp.a(5), pg_temp.a(6)) ORDER BY account_id$$,
    $$VALUES (0::numeric), (0::numeric)$$,
    'balanced accounts end at zero'
);

-- Both flags: 10 has a credit surplus of 20, 11 a debit surplus of 25; the smaller wins.
SELECT results_eq(
    $$SELECT code FROM ledger.create_transfers(ARRAY[
        pg_temp.tr(pg_temp.t(50), pg_temp.a(11), pg_temp.a(10), 20),
        pg_temp.tr(pg_temp.t(51), pg_temp.a(11), pg_temp.a(1), 5),
        pg_temp.tr(pg_temp.t(52), pg_temp.a(10), pg_temp.a(11), 100,
                   balance_debit_account => true, balance_credit_account => true)
    ])$$,
    $$VALUES ('ok'), ('ok'), ('ok')$$,
    'setup and a transfer balancing both sides'
);

SELECT is(
    (SELECT amount FROM ledger.transfers WHERE id = pg_temp.t(52)),
    20::numeric,
    'with both flags the smaller cap wins'
);

SELECT is_empty(
    $$SELECT * FROM ledger.create_transfers(ARRAY[]::ledger.transfer_input[])$$,
    'an empty array returns no rows'
);

SELECT throws_like(
    $$SELECT * FROM ledger.create_transfers(
        ARRAY[ARRAY[pg_temp.tr(pg_temp.t(60), pg_temp.a(1), pg_temp.a(2), 1)]])$$,
    '%one-dimensional array, got 2 dimensions',
    'a multi-dimensional array is an error'
);

SELECT results_eq(
    $$SELECT ord, code FROM ledger.create_transfers(
        '[0:1]={"(c0000000-0000-0000-0000-000000000070,902,b0000000-0000-0000-0000-000000000001,b0000000-0000-0000-0000-000000000002,1,1,,,,)","(c0000000-0000-0000-0000-000000000071,902,b0000000-0000-0000-0000-000000000001,b0000000-0000-0000-0000-000000000002,0,1,,,,)"}'
        ::ledger.transfer_input[])$$,
    $$VALUES (1, 'ok'), (2, 'amount_must_be_positive')$$,
    'an array that does not start at 1 is numbered from 1'
);

SELECT * FROM finish();
ROLLBACK;
