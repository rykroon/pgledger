-- Makes a table append-only. Statement-level so it also covers TRUNCATE.
CREATE OR REPLACE FUNCTION @extschema@.raise_immutable()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION '%.% is append-only: % is not allowed',
        TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP;
END;
$$ LANGUAGE plpgsql;


-- Stamps created_at; callers can't supply it (a generated column can't use now()).
CREATE OR REPLACE FUNCTION @extschema@.set_created_at()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.created_at IS NOT NULL THEN
        RAISE EXCEPTION '%.%.created_at is assigned by the ledger and cannot be supplied',
            TG_TABLE_SCHEMA, TG_TABLE_NAME;
    END IF;
    NEW.created_at := now();
    RETURN NEW;
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

    -- Target of the composite FKs that keep a transfer on one ledger.
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

-- Value flows credit -> debit; the composite FKs make a cross-ledger transfer unwritable.
-- A multi-row INSERT posts its rows in no particular order: the AFTER STATEMENT trigger reads
-- them from a transition table, which has no defined order. When one transfer must post before
-- the next, insert them in separate statements.
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

    CHECK (debit_account_id <> credit_account_id),

    FOREIGN KEY (debit_account_id, ledger_id)  REFERENCES @extschema@.accounts (id, ledger_id),
    FOREIGN KEY (credit_account_id, ledger_id) REFERENCES @extschema@.accounts (id, ledger_id)
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

-- Only post_transfers() may insert: that trigger runs at depth 1, its INSERT at 2.
CREATE OR REPLACE FUNCTION @extschema@.raise_direct_insert()
RETURNS TRIGGER AS $$
BEGIN
    IF pg_trigger_depth() < 2 THEN
        RAISE EXCEPTION '%.% is written by posting transfers; INSERTing into it directly is not allowed',
            TG_TABLE_SCHEMA, TG_TABLE_NAME;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER account_balances_no_direct_insert
    BEFORE INSERT ON @extschema@.account_balances
    FOR EACH STATEMENT EXECUTE FUNCTION @extschema@.raise_direct_insert();

CREATE TRIGGER account_balances_immutable
    BEFORE UPDATE OR DELETE OR TRUNCATE ON @extschema@.account_balances
    FOR EACH STATEMENT EXECUTE FUNCTION @extschema@.raise_immutable();

-- Posts the transfers a statement inserted, as one set-based INSERT: each transfer becomes a
-- debit leg and a credit leg, each touched account's latest totals are read once, and window
-- functions assign versions and running totals per account. The window orders an account's
-- legs by transfer id because running sums need some order; that is an implementation detail
-- of one statement, not an ordering guarantee, and insert in separate statements when one
-- transfer must post before the next. Any failure rolls back the whole statement.
--
-- The balance rules are checked here too, on the rows the INSERT returns, joined to accounts
-- once. accounts is immutable, so a row that passes stays passing.
CREATE OR REPLACE FUNCTION @extschema@.post_transfers()
RETURNS TRIGGER AS $$
DECLARE
    ids uuid[];
    bad record;
BEGIN
    -- Lock every account the statement touches, in id order, so two concurrent statements
    -- sharing accounts cannot deadlock. Holds within one statement only: post a batch as one
    -- INSERT. NO KEY UPDATE because the FK checks hold KEY SHARE, which FOR UPDATE conflicts
    -- with. Under REPEATABLE READ the snapshot can predate the lock; the PK catches that.
    SELECT array_agg(id) INTO ids FROM (
        SELECT debit_account_id AS id FROM new_transfers
        UNION
        SELECT credit_account_id FROM new_transfers
    ) touched;

    -- Nothing inserted, e.g. every row skipped by ON CONFLICT DO NOTHING.
    IF ids IS NULL THEN
        RETURN NULL;
    END IF;

    PERFORM id FROM @extschema@.accounts
    WHERE id = ANY(ids)
    ORDER BY id
    FOR NO KEY UPDATE;

    WITH legs AS (
        SELECT debit_account_id AS account_id, id AS transfer_id,
               amount AS debit, 0::numeric AS credit
        FROM new_transfers
        UNION ALL
        SELECT credit_account_id, id, 0, amount
        FROM new_transfers
    ),
    -- Latest totals per touched account. LATERAL with LIMIT 1 walks the PK backwards; a
    -- DISTINCT ON over the table would read the account's whole history.
    prev AS (
        SELECT a.id AS account_id, b.version, b.debits_posted, b.credits_posted
        FROM unnest(ids) AS a(id)
        LEFT JOIN LATERAL (
            SELECT ab.version, ab.debits_posted, ab.credits_posted
            FROM @extschema@.account_balances ab
            WHERE ab.account_id = a.id
            ORDER BY ab.version DESC
            LIMIT 1
        ) b ON true
    ),
    posted AS (
        INSERT INTO @extschema@.account_balances
            (account_id, version, transfer_id, debits_posted, credits_posted)
        SELECT
            l.account_id,
            COALESCE(p.version, 0)        + row_number()  OVER w,
            l.transfer_id,
            COALESCE(p.debits_posted, 0)  + sum(l.debit)  OVER w,
            COALESCE(p.credits_posted, 0) + sum(l.credit) OVER w
        FROM legs l
        LEFT JOIN prev p USING (account_id)
        WINDOW w AS (PARTITION BY l.account_id ORDER BY l.transfer_id ROWS UNBOUNDED PRECEDING)
        RETURNING account_id, transfer_id, debits_posted, credits_posted
    )
    SELECT p.account_id, p.transfer_id, p.debits_posted, p.credits_posted,
           a.require_credit_balance, a.require_debit_balance
    INTO bad
    FROM posted p
    JOIN @extschema@.accounts a ON a.id = p.account_id
    WHERE (a.require_credit_balance AND p.debits_posted > p.credits_posted)
       OR (a.require_debit_balance  AND p.credits_posted > p.debits_posted)
    LIMIT 1;

    IF FOUND THEN
        IF bad.require_credit_balance THEN
            RAISE EXCEPTION 'account % is credit-normal: transfer % would put debits % past credits %',
                bad.account_id, bad.transfer_id, bad.debits_posted, bad.credits_posted;
        END IF;
        RAISE EXCEPTION 'account % is debit-normal: transfer % would put credits % past debits %',
            bad.account_id, bad.transfer_id, bad.credits_posted, bad.debits_posted;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql
-- The posting statement costs more to plan than to run, and the planner keeps re-planning it
-- because a custom plan for a two-element array always looks cheaper than the generic one.
-- Plan it once; every access path in it is an index lookup whatever the batch size.
SET plan_cache_mode = force_generic_plan;

CREATE TRIGGER transfers_post
    AFTER INSERT ON @extschema@.transfers
    REFERENCING NEW TABLE AS new_transfers
    FOR EACH STATEMENT EXECUTE FUNCTION @extschema@.post_transfers();


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
