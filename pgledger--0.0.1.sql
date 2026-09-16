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


-- Only create_transfers() writes transfers and account_balances. It sets
-- ledger.creating_transfers for the duration of the call, transaction-locally, so
-- a plain INSERT never reaches the tables. A guard rail against bypassing the
-- function's checks, not a privilege boundary: anyone with INSERT can set it too.
CREATE OR REPLACE FUNCTION ledger.raise_unless_creating_transfers()
RETURNS TRIGGER AS $$
BEGIN
    IF current_setting('ledger.creating_transfers', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION 'ledger.% is written by ledger.create_transfers(); INSERT into it directly is not allowed', TG_TABLE_NAME
            USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- A ledger: one unit of value. Deliberately bare; mutable attributes belong in the
-- caller's own table keyed by ledger_id. Immutable; id is a UUIDv7 from the caller.
CREATE TABLE ledger.ledgers (
    id         uuid        PRIMARY KEY,
    created_at timestamptz NOT NULL
);

CREATE TRIGGER ledgers_set_created_at
    BEFORE INSERT ON ledger.ledgers
    FOR EACH ROW EXECUTE FUNCTION ledger.set_created_at();

CREATE TRIGGER ledgers_immutable
    BEFORE UPDATE OR DELETE OR TRUNCATE ON ledger.ledgers
    FOR EACH STATEMENT EXECUTE FUNCTION ledger.raise_immutable();

-- A balance on one ledger. code, external_id and external_timestamp are opaque
-- caller data; nothing is unique beyond id.
--
-- The flags are balance rules enforced by create_transfers(): require_debit_balance
-- keeps credits from exceeding debits, require_credit_balance keeps debits from
-- exceeding credits. Both at once would pin the balance to zero.
--
-- Immutable; id is a UUIDv7 from the caller.
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

CREATE INDEX accounts_external_id_idx ON ledger.accounts (external_id)
    WHERE external_id IS NOT NULL;

CREATE TRIGGER accounts_set_created_at
    BEFORE INSERT ON ledger.accounts
    FOR EACH ROW EXECUTE FUNCTION ledger.set_created_at();

CREATE TRIGGER accounts_immutable
    BEFORE UPDATE OR DELETE OR TRUNCATE ON ledger.accounts
    FOR EACH STATEMENT EXECUTE FUNCTION ledger.raise_immutable();

-- Value flows credit -> debit. The composite FKs make a cross-ledger transfer
-- unwritable. external_timestamp is the caller's own time and changes no ordering.
--
-- Written only by create_transfers(), which stamps created_at with clock_timestamp()
-- per row, so created_at is the order transfers were created in.
--
-- The balancing flags make amount a maximum, clamped by create_transfers():
-- balance_debit_account moves no more than keeps the debit account's debits from
-- exceeding its credits, balance_credit_account no more than keeps the credit
-- account's credits from exceeding its debits. Both at once take the smaller. The
-- clamp can reach zero; amount_posted is what actually moved.
--
-- Immutable; id is a UUIDv7 from the caller.
CREATE TABLE ledger.transfers (
    id                 uuid          PRIMARY KEY,
    created_at         timestamptz   NOT NULL,
    ledger_id          uuid          NOT NULL,
    debit_account_id   uuid          NOT NULL,
    credit_account_id  uuid          NOT NULL,
    amount             numeric(39,0) NOT NULL CHECK (amount > 0),
    amount_posted      numeric(39,0) NOT NULL CHECK (amount_posted >= 0 AND amount_posted <= amount),
    code               integer       NOT NULL CHECK (code > 0),
    external_id        uuid,
    external_timestamp timestamptz,

    balance_debit_account  boolean NOT NULL DEFAULT false,
    balance_credit_account boolean NOT NULL DEFAULT false,

    CHECK (debit_account_id <> credit_account_id),

    FOREIGN KEY (debit_account_id, ledger_id)  REFERENCES ledger.accounts (id, ledger_id),
    FOREIGN KEY (credit_account_id, ledger_id) REFERENCES ledger.accounts (id, ledger_id)
);

CREATE INDEX transfers_debit_account_id_idx ON ledger.transfers (debit_account_id);
CREATE INDEX transfers_credit_account_id_idx ON ledger.transfers (credit_account_id);
-- Serves chronological listings of one ledger's transfers.
CREATE INDEX transfers_ledger_id_created_at_idx ON ledger.transfers (ledger_id, created_at);
CREATE INDEX transfers_external_id_idx ON ledger.transfers (external_id)
    WHERE external_id IS NOT NULL;

CREATE TRIGGER transfers_no_direct_insert
    BEFORE INSERT ON ledger.transfers
    FOR EACH ROW EXECUTE FUNCTION ledger.raise_unless_creating_transfers();

CREATE TRIGGER transfers_immutable
    BEFORE UPDATE OR DELETE OR TRUNCATE ON ledger.transfers
    FOR EACH STATEMENT EXECUTE FUNCTION ledger.raise_immutable();

-- An account's running totals after each transfer, two rows per transfer. Immutable.
--
-- version is previous + 1, assigned under the write lock, so it is gapless and
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

CREATE TRIGGER account_balances_no_direct_insert
    BEFORE INSERT ON ledger.account_balances
    FOR EACH ROW EXECUTE FUNCTION ledger.raise_unless_creating_transfers();

CREATE TRIGGER account_balances_immutable
    BEFORE UPDATE OR DELETE OR TRUNCATE ON ledger.account_balances
    FOR EACH STATEMENT EXECUTE FUNCTION ledger.raise_immutable();


-- Input to create_transfers(): the caller-supplied columns of ledger.transfers.
-- NULL balancing flags mean false.
CREATE TYPE ledger.transfer_input AS (
    id                     uuid,
    ledger_id              uuid,
    debit_account_id       uuid,
    credit_account_id      uuid,
    amount                 numeric(39,0),
    code                   integer,
    external_id            uuid,
    external_timestamp     timestamptz,
    balance_debit_account  boolean,
    balance_credit_account boolean
);


-- Creates and posts transfers in argument order, returning the rows as stored.
-- Order changes outcomes (a deposit then a withdrawal can succeed where the reverse
-- fails). A broken balance rule raises LG001, so callers can tell it apart from
-- other constraint failures; any failure rolls back the whole call.
CREATE OR REPLACE FUNCTION ledger.create_transfers(VARIADIC inputs ledger.transfer_input[])
RETURNS SETOF ledger.transfers AS $$
DECLARE
    i              ledger.transfer_input;
    t              ledger.transfers%ROWTYPE;
    debit_account  ledger.accounts%ROWTYPE;
    credit_account ledger.accounts%ROWTYPE;
    debit_prev     ledger.account_balances%ROWTYPE;
    credit_prev    ledger.account_balances%ROWTYPE;
    debit_debits   numeric(39,0);
    debit_credits  numeric(39,0);
    credit_debits  numeric(39,0);
    credit_credits numeric(39,0);
    posted         numeric(39,0);
BEGIN
    -- One writer at a time, held until the transaction ends. Replaces per-account
    -- row locks: no deadlocks, version never collides, and created_at is the commit
    -- order across the whole ledger. Under REPEATABLE READ or SERIALIZABLE the
    -- snapshot can predate the lock; the account_balances primary key catches that.
    PERFORM pg_advisory_xact_lock(hashtext('ledger.create_transfers'));

    -- Opens the guarded tables for this call only; cleared before returning.
    PERFORM set_config('ledger.creating_transfers', 'on', true);

    FOREACH i IN ARRAY inputs LOOP
        SELECT * INTO debit_account  FROM ledger.accounts WHERE id = i.debit_account_id;
        SELECT * INTO credit_account FROM ledger.accounts WHERE id = i.credit_account_id;

        SELECT * INTO debit_prev FROM ledger.account_balances
        WHERE account_id = i.debit_account_id
        ORDER BY version DESC
        LIMIT 1;

        SELECT * INTO credit_prev FROM ledger.account_balances
        WHERE account_id = i.credit_account_id
        ORDER BY version DESC
        LIMIT 1;

        -- Balancing clamps amount toward zero balance; zero is posted, not rejected.
        posted := i.amount;
        IF COALESCE(i.balance_debit_account, false) THEN
            posted := LEAST(posted, GREATEST(0,
                COALESCE(debit_prev.credits_posted, 0) - COALESCE(debit_prev.debits_posted, 0)));
        END IF;
        IF COALESCE(i.balance_credit_account, false) THEN
            posted := LEAST(posted, GREATEST(0,
                COALESCE(credit_prev.debits_posted, 0) - COALESCE(credit_prev.credits_posted, 0)));
        END IF;

        debit_debits   := COALESCE(debit_prev.debits_posted, 0) + posted;
        debit_credits  := COALESCE(debit_prev.credits_posted, 0);
        credit_debits  := COALESCE(credit_prev.debits_posted, 0);
        credit_credits := COALESCE(credit_prev.credits_posted, 0) + posted;

        -- Debit side gained debits: a credit-normal account cannot go past zero.
        IF debit_account.require_credit_balance AND debit_debits > debit_credits THEN
            RAISE EXCEPTION 'account % is credit-normal: debits % would exceed credits %',
                debit_account.id, debit_debits, debit_credits
                USING ERRCODE = 'LG001';
        END IF;
        IF debit_account.require_debit_balance AND debit_credits > debit_debits THEN
            RAISE EXCEPTION 'account % is debit-normal: credits % would exceed debits %',
                debit_account.id, debit_credits, debit_debits
                USING ERRCODE = 'LG001';
        END IF;

        -- Credit side gained credits: a debit-normal account cannot go past zero.
        IF credit_account.require_debit_balance AND credit_credits > credit_debits THEN
            RAISE EXCEPTION 'account % is debit-normal: credits % would exceed debits %',
                credit_account.id, credit_credits, credit_debits
                USING ERRCODE = 'LG001';
        END IF;
        IF credit_account.require_credit_balance AND credit_debits > credit_credits THEN
            RAISE EXCEPTION 'account % is credit-normal: debits % would exceed credits %',
                credit_account.id, credit_debits, credit_credits
                USING ERRCODE = 'LG001';
        END IF;

        INSERT INTO ledger.transfers
            (id, created_at, ledger_id, debit_account_id, credit_account_id,
             amount, amount_posted, code, external_id, external_timestamp,
             balance_debit_account, balance_credit_account)
        VALUES
            (i.id, clock_timestamp(), i.ledger_id, i.debit_account_id, i.credit_account_id,
             i.amount, posted, i.code, i.external_id, i.external_timestamp,
             COALESCE(i.balance_debit_account, false), COALESCE(i.balance_credit_account, false))
        RETURNING * INTO t;

        INSERT INTO ledger.account_balances
            (account_id, version, transfer_id, debits_posted, credits_posted)
        VALUES
            (t.debit_account_id,  COALESCE(debit_prev.version, 0) + 1,  t.id, debit_debits,  debit_credits),
            (t.credit_account_id, COALESCE(credit_prev.version, 0) + 1, t.id, credit_debits, credit_credits);

        RETURN NEXT t;
    END LOOP;

    -- Close the window so a later plain INSERT in this transaction still fails.
    PERFORM set_config('ledger.creating_transfers', '', true);
END;
$$ LANGUAGE plpgsql;


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
