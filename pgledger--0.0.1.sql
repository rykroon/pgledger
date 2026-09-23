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
    code               integer     NOT NULL CHECK (code > 0),
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
    code               integer       NOT NULL CHECK (code > 0),
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

-- Enforced here rather than in post_transfers() so the rule holds whatever writes the row. The
-- rule is a predicate on the row's own totals, so the trigger needn't know which side of the
-- transfer the row is. accounts is immutable, so a row that passes stays passing.
CREATE OR REPLACE FUNCTION @extschema@.check_balance_rule()
RETURNS TRIGGER AS $$
DECLARE
    require_credit boolean;
    require_debit  boolean;
BEGIN
    SELECT require_credit_balance, require_debit_balance
    INTO require_credit, require_debit
    FROM @extschema@.accounts WHERE id = NEW.account_id;

    IF require_credit AND NEW.debits_posted > NEW.credits_posted THEN
        RAISE EXCEPTION 'account % is credit-normal: transfer % would put debits % past credits %',
            NEW.account_id, NEW.transfer_id, NEW.debits_posted, NEW.credits_posted;
    END IF;

    IF require_debit AND NEW.credits_posted > NEW.debits_posted THEN
        RAISE EXCEPTION 'account % is debit-normal: transfer % would put credits % past debits %',
            NEW.account_id, NEW.transfer_id, NEW.credits_posted, NEW.debits_posted;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER account_balances_check_balance_rule
    BEFORE INSERT ON @extschema@.account_balances
    FOR EACH ROW EXECUTE FUNCTION @extschema@.check_balance_rule();


-- Posts the transfers a statement inserted. The transition table has no defined order, so rows
-- within one statement post in no particular order; insert in separate statements when one
-- transfer must post before the next. Any failure rolls back the whole statement.
CREATE OR REPLACE FUNCTION @extschema@.post_transfers()
RETURNS TRIGGER AS $$
DECLARE
    ids            uuid[];
    t              @extschema@.transfers%ROWTYPE;
    debit_prev     @extschema@.account_balances%ROWTYPE;
    credit_prev    @extschema@.account_balances%ROWTYPE;
    debit_debits   numeric(39,0);
    debit_credits  numeric(39,0);
    credit_debits  numeric(39,0);
    credit_credits numeric(39,0);
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

    FOR t IN SELECT * FROM new_transfers LOOP
        SELECT * INTO debit_prev FROM @extschema@.account_balances
        WHERE account_id = t.debit_account_id
        ORDER BY version DESC
        LIMIT 1;

        SELECT * INTO credit_prev FROM @extschema@.account_balances
        WHERE account_id = t.credit_account_id
        ORDER BY version DESC
        LIMIT 1;

        debit_debits   := COALESCE(debit_prev.debits_posted, 0) + t.amount;
        debit_credits  := COALESCE(debit_prev.credits_posted, 0);
        credit_debits  := COALESCE(credit_prev.debits_posted, 0);
        credit_credits := COALESCE(credit_prev.credits_posted, 0) + t.amount;

        INSERT INTO @extschema@.account_balances
            (account_id, version, transfer_id, debits_posted, credits_posted)
        VALUES
            (t.debit_account_id,  COALESCE(debit_prev.version, 0) + 1,  t.id, debit_debits,  debit_credits),
            (t.credit_account_id, COALESCE(credit_prev.version, 0) + 1, t.id, credit_debits, credit_credits);
    END LOOP;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

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
