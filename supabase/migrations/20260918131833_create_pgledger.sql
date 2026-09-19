-- The install from README.md, verbatim. @extschema@ in the extension script resolves to the
-- schema named here, so this doubles as a check that the substitution survives pg_tle.
CREATE SCHEMA ledger;
CREATE EXTENSION pgledger SCHEMA ledger;
