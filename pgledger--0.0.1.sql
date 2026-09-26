-- Makes a table append-only. Statement-level so it also covers TRUNCATE.
CREATE OR REPLACE FUNCTION @extschema@.raise_immutable()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION '%.% is append-only: % is not allowed',
        TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP;
END;
$$ LANGUAGE plpgsql;


-- Stamps created_at; callers can't supply it (a generated column can't use now()).
-- clock_timestamp(), not now(), so rows in one transaction or statement get their own times.
-- Mostly unique, not unique: two rows can share a microsecond, and the wall clock can step.
CREATE OR REPLACE FUNCTION @extschema@.set_created_at()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.created_at IS NOT NULL THEN
        RAISE EXCEPTION '%.%.created_at is assigned by the ledger and cannot be supplied',
            TG_TABLE_SCHEMA, TG_TABLE_NAME;
    END IF;
    NEW.created_at := clock_timestamp();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- Only create_transfers() may write transfers and account_balances: it sets a
-- transaction-local GUC around its inserts, and anything arriving without it is rejected.
-- (This replaced a pg_trigger_depth() guard: the function's inserts run at depth 0, so
-- trigger depth can no longer tell posting apart from a direct INSERT.)
CREATE OR REPLACE FUNCTION @extschema@.raise_direct_insert()
RETURNS TRIGGER AS $$
BEGIN
    IF current_setting('pgledger.posting', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION '%.% is written by %.create_transfers(); INSERTing into it directly is not allowed',
            TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_TABLE_SCHEMA;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;


-- Deliberately bare; mutable attributes belong in the caller's own table keyed by ledger_id.
CREATE TABLE @extschema@.ledgers (
    id         uuid        PRIMARY KEY,
    created_at timestamptz NOT NULL
);

CREATE INDEX ledgers_created_at_idx ON @extschema@.ledgers (created_at);

CREATE TRIGGER ledgers_set_created_at
    BEFORE INSERT ON @extschema@.ledgers
    FOR EACH ROW EXECUTE FUNCTION @extschema@.set_created_at();

CREATE TRIGGER ledgers_immutable
    BEFORE UPDATE OR DELETE OR TRUNCATE ON @extschema@.ledgers
    FOR EACH STATEMENT EXECUTE FUNCTION @extschema@.raise_immutable();

-- code, external_id and external_timestamp are opaque caller data; nothing is unique beyond
-- id. require_debit_balance keeps credits from exceeding debits, require_credit_balance keeps
-- debits from exceeding credits; both at once would pin the balance to zero.
CREATE TABLE @extschema@.accounts (
    id                 uuid        PRIMARY KEY,
    created_at         timestamptz NOT NULL,
    ledger_id          uuid        NOT NULL REFERENCES @extschema@.ledgers(id),
    code               integer     NOT NULL CHECK (code BETWEEN 1 AND 65535),
    external_id        uuid,
    external_timestamp timestamptz,

    require_credit_balance boolean NOT NULL DEFAULT false,
    require_debit_balance  boolean NOT NULL DEFAULT false,

    CONSTRAINT accounts_one_balance_requirement
        CHECK (NOT (require_credit_balance AND require_debit_balance)),

    -- Was the target of the composite FKs that kept a transfer on one ledger; kept in case
    -- they return.
    UNIQUE (id, ledger_id)
);

CREATE INDEX accounts_created_at_idx ON @extschema@.accounts (created_at);
CREATE INDEX accounts_ledger_id_idx ON @extschema@.accounts (ledger_id);
CREATE INDEX accounts_code_idx ON @extschema@.accounts (code);
CREATE INDEX accounts_external_id_idx ON @extschema@.accounts (external_id)
    WHERE external_id IS NOT NULL;
CREATE INDEX accounts_external_timestamp_idx ON @extschema@.accounts (external_timestamp)
    WHERE external_timestamp IS NOT NULL;

CREATE TRIGGER accounts_set_created_at
    BEFORE INSERT ON @extschema@.accounts
    FOR EACH ROW EXECUTE FUNCTION @extschema@.set_created_at();

CREATE TRIGGER accounts_immutable
    BEFORE UPDATE OR DELETE OR TRUNCATE ON @extschema@.accounts
    FOR EACH STATEMENT EXECUTE FUNCTION @extschema@.raise_immutable();

-- Value flows credit -> debit. Transfers are written only by create_transfers(), which
-- validates account existence and same-ledger membership itself before inserting, so the
-- composite FKs that used to enforce them are gone. The CHECKs stay as backstops: they can
-- only fire if create_transfers() misvalidates, and then failing the whole call is right.
CREATE TABLE @extschema@.transfers (
    id                 uuid          PRIMARY KEY,
    created_at         timestamptz   NOT NULL,
    ledger_id          uuid          NOT NULL,
    debit_account_id   uuid          NOT NULL,
    credit_account_id  uuid          NOT NULL,
    amount             numeric(39,0) NOT NULL CHECK (amount > 0),
    code               integer       NOT NULL CHECK (code BETWEEN 1 AND 65535),
    external_id        uuid,
    external_timestamp timestamptz,

    CHECK (debit_account_id <> credit_account_id)
);

CREATE INDEX transfers_debit_account_id_idx ON @extschema@.transfers (debit_account_id);
CREATE INDEX transfers_credit_account_id_idx ON @extschema@.transfers (credit_account_id);
CREATE INDEX transfers_ledger_id_created_at_idx ON @extschema@.transfers (ledger_id, created_at);
CREATE INDEX transfers_created_at_idx ON @extschema@.transfers (created_at);
CREATE INDEX transfers_code_idx ON @extschema@.transfers (code);
CREATE INDEX transfers_external_id_idx ON @extschema@.transfers (external_id)
    WHERE external_id IS NOT NULL;
CREATE INDEX transfers_external_timestamp_idx ON @extschema@.transfers (external_timestamp)
    WHERE external_timestamp IS NOT NULL;

CREATE TRIGGER transfers_no_direct_insert
    BEFORE INSERT ON @extschema@.transfers
    FOR EACH STATEMENT EXECUTE FUNCTION @extschema@.raise_direct_insert();

CREATE TRIGGER transfers_set_created_at
    BEFORE INSERT ON @extschema@.transfers
    FOR EACH ROW EXECUTE FUNCTION @extschema@.set_created_at();

CREATE TRIGGER transfers_immutable
    BEFORE UPDATE OR DELETE OR TRUNCATE ON @extschema@.transfers
    FOR EACH STATEMENT EXECUTE FUNCTION @extschema@.raise_immutable();

-- An account's running totals after each transfer, two rows per transfer. version is previous
-- + 1, assigned under the account lock, so it is gapless. A writer on a stale snapshot computes
-- an existing version and fails on the primary key instead of forking the chain.
CREATE TABLE @extschema@.account_balances (
    account_id     uuid          NOT NULL REFERENCES @extschema@.accounts(id),
    version        bigint        NOT NULL CHECK (version > 0),
    transfer_id    uuid          NOT NULL REFERENCES @extschema@.transfers(id),
    debits_posted  numeric(39,0) NOT NULL CHECK (debits_posted >= 0),
    credits_posted numeric(39,0) NOT NULL CHECK (credits_posted >= 0),

    PRIMARY KEY (account_id, version),
    UNIQUE (transfer_id, account_id)
);

CREATE TRIGGER account_balances_no_direct_insert
    BEFORE INSERT ON @extschema@.account_balances
    FOR EACH STATEMENT EXECUTE FUNCTION @extschema@.raise_direct_insert();

CREATE TRIGGER account_balances_immutable
    BEFORE UPDATE OR DELETE OR TRUNCATE ON @extschema@.account_balances
    FOR EACH STATEMENT EXECUTE FUNCTION @extschema@.raise_immutable();


-- One row of a create_transfers() batch. Composite types can't carry constraints, so every
-- rule is checked by create_transfers() and reported as a result code, never an exception.
CREATE TYPE @extschema@.transfer_input AS (
    id                 uuid,
    ledger_id          uuid,
    debit_account_id   uuid,
    credit_account_id  uuid,
    amount             numeric,
    code               integer,
    external_id        uuid,
    external_timestamp timestamptz
);

-- Posts a batch with a result per transfer, TigerBeetle-style: a rejected row does not abort
-- its neighbors. Returns one (ord, transfer_id, code) row per input element, in input order;
-- code is 'ok' or the first rule the row broke:
--
--   phase 1, values (the row alone):     id_not_set, amount_must_be_positive,
--       code_invalid, accounts_must_be_different
--   phase 2, relationships (lookups):     id_already_exists, ledger_not_found,
--       debit_account_not_found, credit_account_not_found,
--       debit_account_ledger_mismatch, credit_account_ledger_mismatch
--   phase 3, balance rules (stateful):    exceeds_credits, exceeds_debits
--
-- Validation runs in those three phases, and only rows that clear a phase reach the next;
-- a row's code is the first check it failed. Everything is computed before anything is
-- written: phases 1 and 2 in one set-based pass, then phase 3, then a single insert of the
-- accepted rows into transfers and account_balances. Unlike the old AFTER INSERT trigger,
-- batch order is explicit here — rows post in array order, and running balances follow it.
--
-- Phase 3 is sequential by nature: a rejected transfer is excluded from the balances later
-- rows see, and each row's amount may one day depend on the balance in front of it
-- (balancing transfers). So it runs as one linear walk in memory: every touched account's
-- latest totals are loaded once into arrays, each candidate is checked and applied (or
-- rejected) against those arrays in batch order, and no SQL runs per row. The work is
-- linear in the batch size no matter how many rows are rejected.
--
-- A repeated id within one batch follows TigerBeetle, which the walk gives for free: the
-- first occurrence that posts marks its id taken, later occurrences report
-- id_already_exists exactly as if it had been committed before the batch, and an occurrence
-- that fails leaves the id free for the next one, evaluated on its own merits at its own
-- position.
--
-- Remaining simplification: a concurrent insert of the same id is not caught here and fails
-- the whole call on the primary key (whole-call errors still exist, as in TigerBeetle).
CREATE OR REPLACE FUNCTION @extschema@.create_transfers(inputs @extschema@.transfer_input[])
RETURNS TABLE (ord integer, transfer_id uuid, code text) AS $$
#variable_conflict use_column
DECLARE
    -- Two ideas carry the whole function:
    --   * an "ord" is a row's 1-based position in the inputs array. It is the row's identity
    --     throughout (ids can be NULL or repeated) and the first column of the result.
    --   * a "slot" is a small number, 1..n, given to each distinct account the batch
    --     touches, so the walk can keep account balances in plain arrays indexed by slot.
    -- Arrays are named for one element — candidate_ord[k] is candidate k's ord.

    -- Rows that failed phase 1 or 2, with the code of the check they failed.
    invalid_ord  bigint[];
    invalid_code text[];

    -- Candidates: rows that passed phases 1 and 2, in batch order, 1..candidate_count.
    -- Only what the input doesn't already hold; the rest is read from inputs[ord].
    candidate_count       integer;
    candidate_ord         bigint[];
    candidate_id_group    integer[];   -- same number for rows sharing an id
    candidate_debit_slot  integer[];
    candidate_credit_slot integer[];

    -- Per slot: the account and its running totals, advanced as the walk accepts rows.
    slot_account_id              uuid[];
    slot_debits_posted           numeric[];
    slot_credits_posted          numeric[];
    slot_version                 bigint[];
    slot_requires_debit_balance  boolean[];
    slot_requires_credit_balance boolean[];

    -- Per id group: whether a row with that id has posted in this batch.
    id_group_posted boolean[];

    -- Walk output. Each group is preallocated to its maximum size, filled by subscript
    -- up to its count, and sliced to [1:count] at insert time. Growing arrays element by
    -- element costs about twice as much, and || would copy the whole array on every append.
    -- Accepted rows are built as the tables' own row types, so the inserts are plain
    -- unnests; fields are assigned by name, which keeps working if a column is appended.
    rejected_count integer := 0;
    rejected_ord   bigint[];
    rejected_code  text[];

    accepted_count     integer := 0;
    accepted_transfers @extschema@.transfers[];

    balance_row_count integer := 0;   -- two per accepted transfer
    balance_rows      @extschema@.account_balances[];

    -- The row the walk is on.
    candidate_index            integer;
    candidate                  @extschema@.transfer_input;
    debit_slot                 integer;
    credit_slot                integer;
    amount                     numeric;
    debit_account_new_debits   numeric;
    credit_account_new_credits numeric;
    rejection_code             text;
    new_transfer               @extschema@.transfers;
    new_balance_row            @extschema@.account_balances;
BEGIN
    IF inputs IS NULL OR cardinality(inputs) = 0 THEN
        RETURN;
    END IF;

    -- A declared transfer_input[] still accepts any number of dimensions: Postgres ignores
    -- array dimensions in type declarations. A batch is a list, so anything else is a
    -- caller bug.
    IF array_ndims(inputs) <> 1 THEN
        RAISE EXCEPTION 'create_transfers expects a one-dimensional array, got % dimensions',
            array_ndims(inputs);
    END IF;

    -- ord counts 1, 2, 3, … but the walk reads rows back as inputs[ord], which uses the
    -- array's own indexes, and those can start anywhere ('[0:1]={...}' starts at 0).
    -- Copy such an array into a fresh one, whose indexes always start at 1.
    IF array_lower(inputs, 1) <> 1 THEN
        inputs := ARRAY(SELECT unnest(inputs));
    END IF;

    -- Phases 1 and 2, and the lock-free part of the phase-3 setup, in one pass, before any
    -- lock is taken: the account locks serialize concurrent batches, so everything that
    -- doesn't need them stays outside them. Each CASE assigns the first failing check; the
    -- CASE order is the documented precedence, and phase 2 only ever sees phase-1
    -- survivors.
    WITH p1_values AS (
        -- Phase 1 — values: checks that need only the row itself. No table access. 1e39 is
        -- the first value numeric(39,0) cannot hold, and NaN/Infinity land above it, so the
        -- amount arm also catches those. debit = credit is NULL-safe: a NULL account id
        -- falls through to phase 2's not-found checks.
        SELECT t.ord, t.id, t.ledger_id, t.debit_account_id, t.credit_account_id, t.amount,
               CASE
                   WHEN t.id IS NULL THEN 'id_not_set'
                   WHEN t.amount IS NULL OR t.amount <= 0
                        OR t.amount <> trunc(t.amount) OR t.amount >= 1e39
                       THEN 'amount_must_be_positive'
                   WHEN t.code IS NULL OR t.code NOT BETWEEN 1 AND 65535 THEN 'code_invalid'
                   WHEN t.debit_account_id = t.credit_account_id
                       THEN 'accounts_must_be_different'
               END AS fail
        FROM unnest(inputs) WITH ORDINALITY
             AS t(id, ledger_id, debit_account_id, credit_account_id,
                  amount, code, external_id, external_timestamp, ord)
    ),
    p2_relationships AS (
        -- Phase 2 — relationships: everything that needs a lookup.
        SELECT p.ord,
               CASE
                   WHEN EXISTS (SELECT FROM @extschema@.transfers tx WHERE tx.id = p.id)
                       THEN 'id_already_exists'
                   WHEN l.id  IS NULL THEN 'ledger_not_found'
                   WHEN da.id IS NULL THEN 'debit_account_not_found'
                   WHEN ca.id IS NULL THEN 'credit_account_not_found'
                   WHEN da.ledger_id <> p.ledger_id THEN 'debit_account_ledger_mismatch'
                   WHEN ca.ledger_id <> p.ledger_id THEN 'credit_account_ledger_mismatch'
               END AS fail
        FROM p1_values p
        LEFT JOIN @extschema@.ledgers  l  ON l.id  = p.ledger_id
        LEFT JOIN @extschema@.accounts da ON da.id = p.debit_account_id
        LEFT JOIN @extschema@.accounts ca ON ca.id = p.credit_account_id
        WHERE p.fail IS NULL
    ),
    fails AS (
        SELECT f.ord, f.fail FROM p1_values f WHERE f.fail IS NOT NULL
        UNION ALL
        SELECT f.ord, f.fail FROM p2_relationships f WHERE f.fail IS NOT NULL
    ),
    -- Phase-3 setup: the candidates in batch order, and each distinct touched account as a
    -- numbered slot.
    candidates AS (
        SELECT p.ord, p.id, p.debit_account_id, p.credit_account_id,
               row_number() OVER (ORDER BY p.ord) AS candidate_index,
               dense_rank()  OVER (ORDER BY p.id) AS id_group
        FROM p1_values p
        JOIN p2_relationships r ON r.ord = p.ord
        WHERE r.fail IS NULL
    ),
    -- Every candidate has a debit leg and a credit leg; one dense_rank over the legs'
    -- accounts numbers the slots. Never join candidates back to a slot list instead: in
    -- the generic plan unnest looks like 10 rows, so such a join is planned as nested loops
    -- over CTE scans, quadratic in the batch.
    legs AS (
        SELECT l.candidate_index, l.is_debit_leg, l.account_id,
               dense_rank() OVER (ORDER BY l.account_id) AS slot
        FROM (SELECT cn.candidate_index, true AS is_debit_leg,
                     cn.debit_account_id AS account_id
              FROM candidates cn
              UNION ALL
              SELECT cn.candidate_index, false, cn.credit_account_id
              FROM candidates cn) l
    ),
    -- Rule flags can be read before the lock: accounts is immutable.
    slots AS (
        SELECT sa.slot, sa.account_id, a.require_debit_balance, a.require_credit_balance
        FROM (SELECT DISTINCT lg.slot, lg.account_id FROM legs lg) sa
        JOIN @extschema@.accounts a ON a.id = sa.account_id
    )
    SELECT invalid_arrays.ords, invalid_arrays.codes,
           candidate_arrays.ords, candidate_arrays.id_groups,
           leg_arrays.debit_slots, leg_arrays.credit_slots,
           slot_arrays.account_ids, slot_arrays.requires_debit, slot_arrays.requires_credit
      INTO invalid_ord, invalid_code,
           candidate_ord, candidate_id_group,
           candidate_debit_slot, candidate_credit_slot,
           slot_account_id, slot_requires_debit_balance, slot_requires_credit_balance
    FROM (SELECT COALESCE(array_agg(f.ord  ORDER BY f.ord), '{}') AS ords,
                 COALESCE(array_agg(f.fail ORDER BY f.ord), '{}') AS codes
          FROM fails f) invalid_arrays,
         (SELECT COALESCE(array_agg(cn.ord           ORDER BY cn.candidate_index), '{}') AS ords,
                 COALESCE(array_agg(cn.id_group::int ORDER BY cn.candidate_index), '{}') AS id_groups
          FROM candidates cn) candidate_arrays,
         (SELECT COALESCE(array_agg(lg.slot::int ORDER BY lg.candidate_index)
                              FILTER (WHERE lg.is_debit_leg), '{}') AS debit_slots,
                 COALESCE(array_agg(lg.slot::int ORDER BY lg.candidate_index)
                              FILTER (WHERE NOT lg.is_debit_leg), '{}') AS credit_slots
          FROM legs lg) leg_arrays,
         (SELECT COALESCE(array_agg(sl.account_id             ORDER BY sl.slot), '{}') AS account_ids,
                 COALESCE(array_agg(sl.require_debit_balance  ORDER BY sl.slot), '{}') AS requires_debit,
                 COALESCE(array_agg(sl.require_credit_balance ORDER BY sl.slot), '{}') AS requires_credit
          FROM slots sl) slot_arrays;

    -- Phase 3 — balance rules: one linear walk, oldest candidate first, no SQL per row.
    candidate_count := COALESCE(cardinality(candidate_ord), 0);

    IF candidate_count > 0 THEN
        -- Lock the candidates' accounts, in id order (slots are numbered by account id, so
        -- slot_account_id already is), so concurrent batches sharing accounts cannot
        -- deadlock. From here to commit is the critical section: keep it to load, walk and
        -- insert.
        PERFORM a.id FROM @extschema@.accounts a
        WHERE a.id = ANY(slot_account_id)
        ORDER BY a.id
        FOR NO KEY UPDATE;

        -- Latest totals per slot, in its own statement so the snapshot postdates the lock.
        -- LATERAL with LIMIT 1 walks the PK backwards; a DISTINCT ON over the table would
        -- read the account's whole history.
        SELECT array_agg(COALESCE(b.debits_posted,  0) ORDER BY s.slot),
               array_agg(COALESCE(b.credits_posted, 0) ORDER BY s.slot),
               array_agg(COALESCE(b.version,        0) ORDER BY s.slot)
          INTO slot_debits_posted, slot_credits_posted, slot_version
        FROM unnest(slot_account_id) WITH ORDINALITY AS s(account_id, slot)
        LEFT JOIN LATERAL (
            SELECT ab.version, ab.debits_posted, ab.credits_posted
            FROM @extschema@.account_balances ab
            WHERE ab.account_id = s.account_id
            ORDER BY ab.version DESC
            LIMIT 1
        ) b ON true;
    END IF;

    id_group_posted            := array_fill(false,       ARRAY[candidate_count]);
    rejected_ord               := array_fill(NULL::bigint, ARRAY[candidate_count]);
    rejected_code              := array_fill(NULL::text,   ARRAY[candidate_count]);
    accepted_transfers         := array_fill(NULL::@extschema@.transfers,        ARRAY[candidate_count]);
    balance_rows               := array_fill(NULL::@extschema@.account_balances, ARRAY[2 * candidate_count]);

    -- Each step reads and writes plain array elements; a rejected row changes nothing, so
    -- later rows never see it.
    FOR candidate_index IN 1 .. candidate_count LOOP
        -- An earlier row with this id already posted in this batch.
        IF id_group_posted[candidate_id_group[candidate_index]] THEN
            rejected_count := rejected_count + 1;
            rejected_ord[rejected_count]  := candidate_ord[candidate_index];
            rejected_code[rejected_count] := 'id_already_exists';
            CONTINUE;
        END IF;

        candidate   := inputs[candidate_ord[candidate_index]];
        debit_slot  := candidate_debit_slot[candidate_index];
        credit_slot := candidate_credit_slot[candidate_index];
        -- A balancing transfer would compute its amount here, from the slot balances.
        amount      := candidate.amount;

        -- A transfer only adds debits to its debit account and credits to its credit
        -- account, so each side can only break one rule. Debit account first, as
        -- TigerBeetle orders its checks.
        debit_account_new_debits   := slot_debits_posted[debit_slot]   + amount;
        credit_account_new_credits := slot_credits_posted[credit_slot] + amount;

        IF slot_requires_credit_balance[debit_slot]
           AND debit_account_new_debits > slot_credits_posted[debit_slot] THEN
            rejection_code := 'exceeds_credits';
        ELSIF slot_requires_debit_balance[credit_slot]
              AND credit_account_new_credits > slot_debits_posted[credit_slot] THEN
            rejection_code := 'exceeds_debits';
        ELSE
            rejection_code := NULL;
        END IF;

        IF rejection_code IS NOT NULL THEN
            rejected_count := rejected_count + 1;
            rejected_ord[rejected_count]  := candidate_ord[candidate_index];
            rejected_code[rejected_count] := rejection_code;
            CONTINUE;
        END IF;

        -- Accepted: advance both accounts and record the transfer and its two balance rows.
        slot_debits_posted[debit_slot]   := debit_account_new_debits;
        slot_credits_posted[credit_slot] := credit_account_new_credits;
        slot_version[debit_slot]  := slot_version[debit_slot]  + 1;
        slot_version[credit_slot] := slot_version[credit_slot] + 1;
        id_group_posted[candidate_id_group[candidate_index]] := true;

        -- created_at is never assigned, so it stays NULL for set_created_at to fill.
        new_transfer.id                 := candidate.id;
        new_transfer.ledger_id          := candidate.ledger_id;
        new_transfer.debit_account_id   := candidate.debit_account_id;
        new_transfer.credit_account_id  := candidate.credit_account_id;
        new_transfer.amount             := amount;   -- the walk's amount, not the input's
        new_transfer.code               := candidate.code;
        new_transfer.external_id        := candidate.external_id;
        new_transfer.external_timestamp := candidate.external_timestamp;
        accepted_count := accepted_count + 1;
        accepted_transfers[accepted_count] := new_transfer;

        new_balance_row.transfer_id    := candidate.id;
        new_balance_row.account_id     := slot_account_id[debit_slot];
        new_balance_row.version        := slot_version[debit_slot];
        new_balance_row.debits_posted  := slot_debits_posted[debit_slot];
        new_balance_row.credits_posted := slot_credits_posted[debit_slot];
        balance_row_count := balance_row_count + 1;
        balance_rows[balance_row_count] := new_balance_row;

        new_balance_row.account_id     := slot_account_id[credit_slot];
        new_balance_row.version        := slot_version[credit_slot];
        new_balance_row.debits_posted  := slot_debits_posted[credit_slot];
        new_balance_row.credits_posted := slot_credits_posted[credit_slot];
        balance_row_count := balance_row_count + 1;
        balance_rows[balance_row_count] := new_balance_row;
    END LOOP;

    -- Opens the write path for the guard triggers; reset below keeps the window tight.
    PERFORM set_config('pgledger.posting', 'on', true);

    -- One statement writes both tables and assembles the results. The accepted rows are
    -- already whole table rows, in batch order.
    RETURN QUERY
    WITH insert_transfers AS (
        INSERT INTO @extschema@.transfers
        SELECT * FROM unnest(accepted_transfers[1:accepted_count])
    ),
    insert_balance_rows AS (
        INSERT INTO @extschema@.account_balances
        SELECT * FROM unnest(balance_rows[1:balance_row_count])
    )
    -- Every input row gets a result: its rejection code if it failed any phase, else 'ok'.
    SELECT t.ord::integer, t.id, COALESCE(rejection.code, 'ok')
    FROM unnest(inputs) WITH ORDINALITY
         AS t(id, ledger_id, debit_account_id, credit_account_id,
              amount, code, external_id, external_timestamp, ord)
    LEFT JOIN unnest(invalid_ord  || rejected_ord[1:rejected_count],
                     invalid_code || rejected_code[1:rejected_count])
         AS rejection(ord, code) ON rejection.ord = t.ord
    ORDER BY t.ord;

    PERFORM set_config('pgledger.posting', '', true);
END;
$$ LANGUAGE plpgsql
-- The statements cost more to plan than to run, and the planner keeps re-planning them
-- because a custom plan for a small array always looks cheaper than the generic one. Plan
-- once; every access path is an index lookup whatever the batch size.
SET plan_cache_mode = force_generic_plan;


-- Every account's latest totals, zeros if never posted to. Upgrades can only append columns.
CREATE VIEW @extschema@.current_balances AS
SELECT
    a.id        AS account_id,
    a.ledger_id,
    COALESCE(b.version,        0) AS version,
    COALESCE(b.debits_posted,  0) AS debits_posted,
    COALESCE(b.credits_posted, 0) AS credits_posted,
    COALESCE(b.debits_posted,  0) - COALESCE(b.credits_posted, 0) AS balance
FROM @extschema@.accounts a
LEFT JOIN LATERAL (
    SELECT ab.version, ab.debits_posted, ab.credits_posted
    FROM @extschema@.account_balances ab
    WHERE ab.account_id = a.id
    ORDER BY ab.version DESC
    LIMIT 1
) b ON true;
