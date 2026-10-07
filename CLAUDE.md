# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

pgledger is a double-entry ledger shipped as a Postgres extension, modeled on TigerBeetle. The
whole extension is one SQL script, `pgledger--0.0.1.sql`; `README.md` is the user-facing
contract (result codes, balance rules, balancing transfers, concurrency guarantees) and must be
kept in sync with any behavior change.
