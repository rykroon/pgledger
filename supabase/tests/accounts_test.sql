-- create_accounts(): one result per input row, in order, and only 'ok' rows are written.
-- Accounts here live in ledger 901 so the seed data (ledger 1) doesn't show up in counts.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(9);

-- a(n) is the nth test account id.
CREATE FUNCTION pg_temp.a(n integer) RETURNS uuid LANGUAGE sql AS $$
    SELECT format('a0000000-0000-0000-0000-%s', lpad(n::text, 12, '0'))::uuid
$$;

CREATE FUNCTION pg_temp.acct(id uuid, ledger integer, code numeric,
                             require_credit_balance boolean DEFAULT NULL,
                             require_debit_balance  boolean DEFAULT NULL)
RETURNS ledger.account_input LANGUAGE sql AS $$
    SELECT ROW(id, ledger, code, NULL, NULL,
               require_credit_balance, require_debit_balance)::ledger.account_input
$$;

SELECT results_eq(
    $$SELECT ord, code FROM ledger.create_accounts(ARRAY[
        pg_temp.acct(pg_temp.a(1), 901, 1),
        pg_temp.acct(NULL,         901, 1),
        pg_temp.acct(pg_temp.a(3), 0,   1),
        pg_temp.acct(pg_temp.a(4), NULL, 1),
        pg_temp.acct(pg_temp.a(5), 901, 0),
        pg_temp.acct(pg_temp.a(6), 901, 100000),
        pg_temp.acct(pg_temp.a(7), 901, 1.5),
        pg_temp.acct(pg_temp.a(8), 901, NULL),
        pg_temp.acct(pg_temp.a(9), 901, 1, true, true),
        pg_temp.acct(pg_temp.a(1), 901, 1),
        pg_temp.acct(pg_temp.a(11), 901, 99999),
        pg_temp.acct(pg_temp.a(12), 901, 0),
        pg_temp.acct(pg_temp.a(12), 901, 1)
    ])$$,
    $$VALUES (1, 'ok'), (2, 'id_not_set'), (3, 'ledger_invalid'), (4, 'ledger_invalid'),
             (5, 'code_invalid'), (6, 'code_invalid'), (7, 'code_invalid'), (8, 'code_invalid'),
             (9, 'flags_are_mutually_exclusive'), (10, 'id_already_exists'), (11, 'ok'),
             (12, 'code_invalid'), (13, 'ok')$$,
    'each row gets the first failed check; a rejected first copy of an id does not block a later one'
);

SELECT results_eq(
    $$SELECT id FROM ledger.accounts WHERE ledger = 901 ORDER BY id$$,
    $$VALUES (pg_temp.a(1)), (pg_temp.a(11)), (pg_temp.a(12))$$,
    'only ok rows are written'
);

SELECT results_eq(
    $$SELECT require_credit_balance, require_debit_balance, created_at IS NOT NULL
      FROM ledger.accounts WHERE id = pg_temp.a(1)$$,
    $$VALUES (false, false, true)$$,
    'NULL balance requirements are stored as false and created_at is stamped'
);

SELECT results_eq(
    $$SELECT ord, code FROM ledger.create_accounts(ARRAY[
        pg_temp.acct(pg_temp.a(1), 901, 1),
        pg_temp.acct(pg_temp.a(20), 901, 1, true, false),
        pg_temp.acct(pg_temp.a(21), 901, 1, false, true)
    ])$$,
    $$VALUES (1, 'id_already_exists'), (2, 'ok'), (3, 'ok')$$,
    'an id already in accounts is rejected; one balance requirement on its own is fine'
);

SELECT results_eq(
    $$SELECT account_id FROM ledger.create_accounts(ARRAY[pg_temp.acct(pg_temp.a(30), 901, 1)])$$,
    $$VALUES (pg_temp.a(30))$$,
    'the result carries the account id'
);

SELECT is_empty(
    $$SELECT * FROM ledger.create_accounts(ARRAY[]::ledger.account_input[])$$,
    'an empty array returns no rows'
);

SELECT is_empty(
    $$SELECT * FROM ledger.create_accounts(NULL)$$,
    'NULL returns no rows'
);

SELECT throws_like(
    $$SELECT * FROM ledger.create_accounts(
        ARRAY[ARRAY[pg_temp.acct(pg_temp.a(40), 901, 1)]])$$,
    '%one-dimensional array, got 2 dimensions',
    'a multi-dimensional array is an error'
);

-- The table owner gets past the no-direct-insert trigger, so the CHECKs are what's left.
SELECT throws_ok(
    $$INSERT INTO ledger.accounts VALUES (pg_temp.a(41), now(), 901, 0, NULL, NULL, false, false)$$,
    '23514',
    NULL,
    'the CHECKs back up create_accounts() for a direct insert by the owner'
);

SELECT * FROM finish();
ROLLBACK;
