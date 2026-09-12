CREATE SCHEMA ledger;


-- Makes a table append-only. Statement-level so it also covers TRUNCATE and
-- reports attempts that match no rows.
CREATE OR REPLACE FUNCTION ledger.raise_immutable()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'ledger.% is append-only: % is not allowed', TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'restrict_violation';
END;
$$ LANGUAGE plpgsql;


-- A balance on one ledger. A NULL external_user_id marks the ledger's issuer,
-- whose balance is the outstanding supply; otherwise it is a user's balance.
--
-- ledger_id and external_user_id are opaque ids supplied by the caller. Neither
-- refers to anything this extension owns, and neither is enforced.
--
-- The flags are the overdraft rules, enforced by post_transfer(): a user cannot be
-- overdrawn (require_debit_balance) and the issuer's supply cannot go
-- negative (require_credit_balance). At most one may be set: an account whose
-- balance had to stay on both sides could only ever hold zero.
--
-- Immutable; balances live in account_balances. id is a UUIDv7 from the caller.
CREATE TABLE ledger.accounts (
    id               uuid        PRIMARY KEY,
    created_at       timestamptz NOT NULL DEFAULT now(),
    ledger_id        uuid        NOT NULL,
    external_user_id uuid,

    require_credit_balance boolean NOT NULL DEFAULT false,
    require_debit_balance  boolean NOT NULL DEFAULT false,

    CONSTRAINT accounts_one_balance_requirement
        CHECK (NOT (require_credit_balance AND require_debit_balance)),

    -- One account per user per ledger; NULLS NOT DISTINCT makes it one issuer too.
    UNIQUE NULLS NOT DISTINCT (ledger_id, external_user_id), -- I dont think we need this
    -- Target of the composite FKs that keep a transfer on one ledger.
    UNIQUE (id, ledger_id)
);

CREATE INDEX accounts_external_user_id_idx ON ledger.accounts (external_user_id);

CREATE TRIGGER accounts_immutable
    BEFORE UPDATE OR DELETE OR TRUNCATE ON ledger.accounts
    FOR EACH STATEMENT EXECUTE FUNCTION ledger.raise_immutable();

-- Value flows credit -> debit: a grant debits the user and credits the issuer; a
-- deduction swaps them. The composite FKs on ledger_id make a cross-ledger
-- transfer unwritable.
--
-- created_at is transaction time; the order transfers were applied is
-- account_balances.applied_at. Immutable; id is a UUIDv7 from the caller.
CREATE TABLE ledger.transfers (
    id                uuid          PRIMARY KEY,
    created_at        timestamptz   NOT NULL DEFAULT now(),
    ledger_id         uuid          NOT NULL,
    debit_account_id  uuid          NOT NULL,
    credit_account_id uuid          NOT NULL,
    amount            numeric(39,0) NOT NULL CHECK (amount > 0),

    CHECK (debit_account_id <> credit_account_id),

    FOREIGN KEY (debit_account_id, ledger_id)  REFERENCES ledger.accounts (id, ledger_id),
    FOREIGN KEY (credit_account_id, ledger_id) REFERENCES ledger.accounts (id, ledger_id)
);

CREATE INDEX transfers_debit_account_id_idx ON ledger.transfers (debit_account_id);
CREATE INDEX transfers_credit_account_id_idx ON ledger.transfers (credit_account_id);
-- Serves chronological listings of one ledger's transfers.
CREATE INDEX transfers_ledger_id_created_at_idx ON ledger.transfers (ledger_id, created_at);

CREATE TRIGGER transfers_immutable
    BEFORE UPDATE OR DELETE OR TRUNCATE ON ledger.transfers
    FOR EACH STATEMENT EXECUTE FUNCTION ledger.raise_immutable();

-- An account's running totals after each transfer: two rows per transfer, so any
-- past balance is readable. Immutable.
--
-- applied_at comes from clock_timestamp() under the account lock, never from the
-- transfer, because lock order is the chain's order and the transfer's timestamp
-- can disagree with it under concurrency. UNIQUE (account_id, applied_at) enforces
-- that no two postings share a microsecond and serves the latest-balance lookup.
CREATE TABLE ledger.account_balances (
    transfer_id    uuid          NOT NULL REFERENCES ledger.transfers(id),
    account_id     uuid          NOT NULL REFERENCES ledger.accounts(id),
    debits_posted  numeric(39,0) NOT NULL CHECK (debits_posted >= 0),
    credits_posted numeric(39,0) NOT NULL CHECK (credits_posted >= 0),
    applied_at     timestamptz   NOT NULL,

    PRIMARY KEY (transfer_id, account_id),
    UNIQUE (account_id, applied_at)
);

CREATE TRIGGER account_balances_immutable
    BEFORE UPDATE OR DELETE OR TRUNCATE ON ledger.account_balances
    FOR EACH STATEMENT EXECUTE FUNCTION ledger.raise_immutable();


-- Posts every transfer an INSERT created: appends two balance rows per transfer
-- and enforces the overdraft flags. A transfer that would break one raises LG001,
-- a dedicated errcode so callers can tell it apart from other constraint failures.
CREATE OR REPLACE FUNCTION ledger.post_transfer()
RETURNS TRIGGER AS $$
DECLARE
    ids            uuid[];
    t              ledger.transfers%ROWTYPE;
    debit_account  ledger.accounts%ROWTYPE;
    credit_account ledger.accounts%ROWTYPE;
    debit_prev     ledger.account_balances%ROWTYPE;
    credit_prev    ledger.account_balances%ROWTYPE;
    debit_debits   numeric(39,0);
    debit_credits  numeric(39,0);
    credit_debits  numeric(39,0);
    credit_credits numeric(39,0);
    applied        timestamptz;
BEGIN
    -- Locks every account the statement touches in one pass, sorted by id, so
    -- concurrent statements lock in the same order and can only wait on each other,
    -- never deadlock. Sorted within one statement only: post a batch as one INSERT.
    -- FOR NO KEY UPDATE, not FOR UPDATE: the FK checks already hold FOR KEY SHARE
    -- on these rows, and FOR UPDATE would conflict with it.
    SELECT array_agg(DISTINCT a ORDER BY a) INTO ids
    FROM new_transfers, LATERAL (VALUES (debit_account_id), (credit_account_id)) v(a);

    IF ids IS NULL THEN
        RETURN NULL;
    END IF;

    PERFORM id FROM ledger.accounts
    WHERE id = ANY(ids)
    ORDER BY id
    FOR NO KEY UPDATE;

    -- Transition tables have no row order, and order changes outcomes (a grant then
    -- a deduction can succeed where the reverse fails), so post in id order. UUIDv7
    -- ids generated in sequence make that the order the caller created them.
    FOR t IN SELECT * FROM new_transfers ORDER BY id LOOP
        SELECT * INTO debit_account  FROM ledger.accounts WHERE id = t.debit_account_id;
        SELECT * INTO credit_account FROM ledger.accounts WHERE id = t.credit_account_id;

        SELECT * INTO debit_prev FROM ledger.account_balances
        WHERE account_id = t.debit_account_id
        ORDER BY applied_at DESC
        LIMIT 1;

        SELECT * INTO credit_prev FROM ledger.account_balances
        WHERE account_id = t.credit_account_id
        ORDER BY applied_at DESC
        LIMIT 1;

        debit_debits   := COALESCE(debit_prev.debits_posted, 0) + t.amount;
        debit_credits  := COALESCE(debit_prev.credits_posted, 0);
        credit_debits  := COALESCE(credit_prev.debits_posted, 0);
        credit_credits := COALESCE(credit_prev.credits_posted, 0) + t.amount;

        -- Debit side gained debits: an issuer cannot redeem past what it issued.
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

        -- Credit side gained credits: a user cannot be overdrawn.
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

        applied := clock_timestamp();

        INSERT INTO ledger.account_balances
            (transfer_id, account_id, debits_posted, credits_posted, applied_at)
        VALUES
            (t.id, t.debit_account_id,  debit_debits,  debit_credits,  applied),
            (t.id, t.credit_account_id, credit_debits, credit_credits, applied);
    END LOOP;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER transfers_post
    AFTER INSERT ON ledger.transfers
    REFERENCING NEW TABLE AS new_transfers
    FOR EACH STATEMENT EXECUTE FUNCTION ledger.post_transfer();


-- Every account's latest balance, with zeros if never posted to. balance is
-- debits minus credits: users read positive, the issuer negative, so a ledger
-- sums to zero.
CREATE VIEW ledger.current_balances AS
SELECT
    a.id        AS account_id,
    a.ledger_id,
    a.external_user_id,
    COALESCE(b.debits_posted,  0) AS debits_posted,
    COALESCE(b.credits_posted, 0) AS credits_posted,
    COALESCE(b.debits_posted,  0) - COALESCE(b.credits_posted, 0) AS balance,
    b.applied_at
FROM ledger.accounts a
LEFT JOIN LATERAL (
    SELECT ab.debits_posted, ab.credits_posted, ab.applied_at
    FROM ledger.account_balances ab
    WHERE ab.account_id = a.id
    ORDER BY ab.applied_at DESC
    LIMIT 1
) b ON true;
