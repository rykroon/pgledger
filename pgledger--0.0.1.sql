CREATE SCHEMA ledger;


-- Makes a table append-only. Statement-level so it also covers TRUNCATE.
CREATE OR REPLACE FUNCTION ledger.raise_immutable()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'ledger.% is append-only: % is not allowed', TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'restrict_violation';
END;
$$ LANGUAGE plpgsql;


-- Stamps created_at; callers can't supply it (a generated column can't use now()).
-- created_at has no DEFAULT, so with this trigger disabled NOT NULL fails inserts.
CREATE OR REPLACE FUNCTION ledger.set_created_at()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.created_at IS NOT NULL THEN
        RAISE EXCEPTION 'ledger.%.created_at is assigned by the ledger and cannot be supplied', TG_TABLE_NAME
            USING ERRCODE = 'generated_always';
    END IF;
    NEW.created_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- A ledger: one unit of value. Deliberately bare; mutable attributes belong in the
-- caller's own table keyed by ledger_id. Immutable; id is a UUIDv7 from the caller.
CREATE TABLE ledger.ledgers (
    id         uuid        PRIMARY KEY,
    created_at timestamptz NOT NULL
);

CREATE INDEX ledgers_created_at_idx ON ledger.ledgers (created_at);

CREATE TRIGGER ledgers_set_created_at
    BEFORE INSERT ON ledger.ledgers
    FOR EACH ROW EXECUTE FUNCTION ledger.set_created_at();

CREATE TRIGGER ledgers_immutable
    BEFORE UPDATE OR DELETE OR TRUNCATE ON ledger.ledgers
    FOR EACH STATEMENT EXECUTE FUNCTION ledger.raise_immutable();

-- A balance on one ledger. code, external_id and external_timestamp are opaque
-- caller data; nothing is unique beyond id.
--
-- The flags are balance rules enforced as each account_balances row is written:
-- require_debit_balance keeps credits from exceeding debits, require_credit_balance
-- keeps debits from exceeding credits. Both at once would pin the balance to zero.
--
-- Immutable; id is a UUID from the caller.
CREATE TABLE ledger.accounts (
    id                 uuid        PRIMARY KEY,
    created_at         timestamptz NOT NULL,
    ledger_id          uuid        NOT NULL REFERENCES ledger.ledgers(id),
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

-- UNIQUE (id, ledger_id) leads with id, so it can't serve ledger_id lookups.
CREATE INDEX accounts_created_at_idx ON ledger.accounts (created_at);
CREATE INDEX accounts_ledger_id_idx ON ledger.accounts (ledger_id);
CREATE INDEX accounts_code_idx ON ledger.accounts (code);
CREATE INDEX accounts_external_id_idx ON ledger.accounts (external_id)
    WHERE external_id IS NOT NULL;
CREATE INDEX accounts_external_timestamp_idx ON ledger.accounts (external_timestamp)
    WHERE external_timestamp IS NOT NULL;

CREATE TRIGGER accounts_set_created_at
    BEFORE INSERT ON ledger.accounts
    FOR EACH ROW EXECUTE FUNCTION ledger.set_created_at();

CREATE TRIGGER accounts_immutable
    BEFORE UPDATE OR DELETE OR TRUNCATE ON ledger.accounts
    FOR EACH STATEMENT EXECUTE FUNCTION ledger.raise_immutable();

-- Value flows credit -> debit. The composite FKs make a cross-ledger transfer
-- unwritable. external_timestamp is the caller's own time and changes no ordering.
--
-- seq is assigned as each row is inserted, so a multi-row INSERT numbers its rows
-- in the order they were written, and post_transfers() applies them in that order.
-- It is allocation order, not commit order: a lower seq can commit later, so it is
-- a sort key and tiebreak, not a change cursor. created_at is the inserting
-- transaction's time, as on the other tables, so a batch shares one value.
--
-- Immutable; id is a UUIDv7 from the caller.
CREATE TABLE ledger.transfers (
    id                 uuid          PRIMARY KEY,
    seq                bigint        GENERATED ALWAYS AS IDENTITY UNIQUE,
    created_at         timestamptz   NOT NULL,
    ledger_id          uuid          NOT NULL,
    debit_account_id   uuid          NOT NULL,
    credit_account_id  uuid          NOT NULL,
    amount             numeric(39,0) NOT NULL CHECK (amount > 0),
    code               integer       NOT NULL CHECK (code > 0),
    external_id        uuid,
    external_timestamp timestamptz,

    CHECK (debit_account_id <> credit_account_id),

    FOREIGN KEY (debit_account_id, ledger_id)  REFERENCES ledger.accounts (id, ledger_id),
    FOREIGN KEY (credit_account_id, ledger_id) REFERENCES ledger.accounts (id, ledger_id)
);

CREATE INDEX transfers_debit_account_id_idx ON ledger.transfers (debit_account_id);
CREATE INDEX transfers_credit_account_id_idx ON ledger.transfers (credit_account_id);
-- Serves ledger_id lookups and chronological listings of one ledger's transfers.
CREATE INDEX transfers_ledger_id_created_at_idx ON ledger.transfers (ledger_id, created_at);
CREATE INDEX transfers_created_at_idx ON ledger.transfers (created_at);
CREATE INDEX transfers_code_idx ON ledger.transfers (code);
CREATE INDEX transfers_external_id_idx ON ledger.transfers (external_id)
    WHERE external_id IS NOT NULL;
CREATE INDEX transfers_external_timestamp_idx ON ledger.transfers (external_timestamp)
    WHERE external_timestamp IS NOT NULL;

CREATE TRIGGER transfers_set_created_at
    BEFORE INSERT ON ledger.transfers
    FOR EACH ROW EXECUTE FUNCTION ledger.set_created_at();

CREATE TRIGGER transfers_immutable
    BEFORE UPDATE OR DELETE OR TRUNCATE ON ledger.transfers
    FOR EACH STATEMENT EXECUTE FUNCTION ledger.raise_immutable();

-- An account's running totals after each transfer, two rows per transfer. Immutable.
--
-- version is previous + 1, assigned under the account lock, so it is gapless and
-- can't go backwards like a clock. A writer on a stale snapshot computes an
-- existing version and fails on the primary key instead of forking the chain.
--
-- Balance isn't stored: it's the totals' difference, sign left to the reader.
CREATE TABLE ledger.account_balances (
    account_id     uuid          NOT NULL REFERENCES ledger.accounts(id),
    version        bigint        NOT NULL CHECK (version > 0),
    transfer_id    uuid          NOT NULL REFERENCES ledger.transfers(id),
    debits_posted  numeric(39,0) NOT NULL CHECK (debits_posted >= 0),
    credits_posted numeric(39,0) NOT NULL CHECK (credits_posted >= 0),

    PRIMARY KEY (account_id, version),
    UNIQUE (transfer_id, account_id)
);

-- Only post_transfers() may insert: that trigger runs at depth 1, its INSERT at 2.
CREATE OR REPLACE FUNCTION ledger.raise_direct_insert()
RETURNS TRIGGER AS $$
BEGIN
    IF pg_trigger_depth() < 2 THEN
        RAISE EXCEPTION 'ledger.% is written by posting transfers; INSERT into it directly is not allowed', TG_TABLE_NAME
            USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER account_balances_no_direct_insert
    BEFORE INSERT ON ledger.account_balances
    FOR EACH STATEMENT EXECUTE FUNCTION ledger.raise_direct_insert();

CREATE TRIGGER account_balances_immutable
    BEFORE UPDATE OR DELETE OR TRUNCATE ON ledger.account_balances
    FOR EACH STATEMENT EXECUTE FUNCTION ledger.raise_immutable();

-- A balance row must satisfy its account's balance rule. Enforced here rather than in
-- post_transfers() so the rule holds whatever writes the row. Each rule is stated once:
-- the trigger doesn't know which side of the transfer the row is, and doesn't need to,
-- because the rule is a predicate on the row's own totals. accounts is immutable, so a
-- row that passes stays passing.
CREATE OR REPLACE FUNCTION ledger.check_balance_rule()
RETURNS TRIGGER AS $$
DECLARE
    require_credit boolean;
    require_debit  boolean;
BEGIN
    SELECT require_credit_balance, require_debit_balance
    INTO require_credit, require_debit
    FROM ledger.accounts WHERE id = NEW.account_id;

    IF require_credit AND NEW.debits_posted > NEW.credits_posted THEN
        RAISE EXCEPTION 'account % is credit-normal: transfer % would put debits % past credits %',
            NEW.account_id, NEW.transfer_id, NEW.debits_posted, NEW.credits_posted
            USING ERRCODE = 'LG001';
    END IF;

    IF require_debit AND NEW.credits_posted > NEW.debits_posted THEN
        RAISE EXCEPTION 'account % is debit-normal: transfer % would put credits % past debits %',
            NEW.account_id, NEW.transfer_id, NEW.credits_posted, NEW.debits_posted
            USING ERRCODE = 'LG001';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER account_balances_check_balance_rule
    BEFORE INSERT ON ledger.account_balances
    FOR EACH ROW EXECUTE FUNCTION ledger.check_balance_rule();


-- Posts the transfers a statement inserted, in seq order, so a multi-row INSERT is
-- applied in the order it was written. Order changes outcomes (a deposit then a
-- withdrawal can succeed where the reverse fails). A broken balance rule raises
-- LG001, so callers can tell it apart from other constraint failures; any failure
-- rolls back the whole statement.
CREATE OR REPLACE FUNCTION ledger.post_transfers()
RETURNS TRIGGER AS $$
DECLARE
    ids            uuid[];
    t              ledger.transfers%ROWTYPE;
    debit_prev     ledger.account_balances%ROWTYPE;
    credit_prev    ledger.account_balances%ROWTYPE;
    debit_debits   numeric(39,0);
    debit_credits  numeric(39,0);
    credit_debits  numeric(39,0);
    credit_credits numeric(39,0);
BEGIN
    -- Lock every account the statement touches, in id order, so two concurrent
    -- statements sharing accounts take them the same way round and cannot deadlock.
    -- The order holds within one statement only: post a batch as one INSERT. Held
    -- until the transaction ends. NO KEY UPDATE because the foreign key checks hold
    -- KEY SHARE on these rows, which FOR UPDATE would conflict with. Under REPEATABLE
    -- READ or SERIALIZABLE the snapshot can predate the lock; the account_balances
    -- primary key catches that.
    SELECT array_agg(id) INTO ids FROM (
        SELECT debit_account_id AS id FROM new_transfers
        UNION
        SELECT credit_account_id FROM new_transfers
    ) touched;

    -- Nothing inserted, e.g. every row skipped by ON CONFLICT DO NOTHING.
    IF ids IS NULL THEN
        RETURN NULL;
    END IF;

    PERFORM id FROM ledger.accounts
    WHERE id = ANY(ids)
    ORDER BY id
    FOR NO KEY UPDATE;

    FOR t IN SELECT * FROM new_transfers ORDER BY seq LOOP
        SELECT * INTO debit_prev FROM ledger.account_balances
        WHERE account_id = t.debit_account_id
        ORDER BY version DESC
        LIMIT 1;

        SELECT * INTO credit_prev FROM ledger.account_balances
        WHERE account_id = t.credit_account_id
        ORDER BY version DESC
        LIMIT 1;

        debit_debits   := COALESCE(debit_prev.debits_posted, 0) + t.amount;
        debit_credits  := COALESCE(debit_prev.credits_posted, 0);
        credit_debits  := COALESCE(credit_prev.debits_posted, 0);
        credit_credits := COALESCE(credit_prev.credits_posted, 0) + t.amount;

        INSERT INTO ledger.account_balances
            (account_id, version, transfer_id, debits_posted, credits_posted)
        VALUES
            (t.debit_account_id,  COALESCE(debit_prev.version, 0) + 1,  t.id, debit_debits,  debit_credits),
            (t.credit_account_id, COALESCE(credit_prev.version, 0) + 1, t.id, credit_debits, credit_credits);
    END LOOP;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER transfers_post
    AFTER INSERT ON ledger.transfers
    REFERENCING NEW TABLE AS new_transfers
    FOR EACH STATEMENT EXECUTE FUNCTION ledger.post_transfers();


-- Every account's latest totals, zeros if never posted to. balance is debits minus
-- credits, so a ledger sums to zero. Upgrades can only append columns.
CREATE VIEW ledger.current_balances AS
SELECT
    a.id        AS account_id,
    a.ledger_id,
    COALESCE(b.version,        0) AS version,
    COALESCE(b.debits_posted,  0) AS debits_posted,
    COALESCE(b.credits_posted, 0) AS credits_posted,
    COALESCE(b.debits_posted,  0) - COALESCE(b.credits_posted, 0) AS balance
FROM ledger.accounts a
LEFT JOIN LATERAL (
    SELECT ab.version, ab.debits_posted, ab.credits_posted
    FROM ledger.account_balances ab
    WHERE ab.account_id = a.id
    ORDER BY ab.version DESC
    LIMIT 1
) b ON true;
