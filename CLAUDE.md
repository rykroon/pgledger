# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

pgledger is a double-entry ledger shipped as a Postgres extension, modeled on TigerBeetle. The
whole extension is one SQL script, `pgledger--0.0.1.sql`;

# Design

pgledger is meant to be influenced by Tigerbeetle.
The tigerbeetle docs can be found here: https://docs.tigerbeetle.com/

Some design goals to consider:

## Immutability
- Tables must be INSERT only. UPDATES and DELETES should fail.
  - This can best be done using a BEFORE trigger.
- Users should not be allowed to directly insert into transfers and account_balances.

## Postgres First
- Do not force Tigerbeetle implementations that do not make sense within the context of Postgres. 
- For example, in Tigerbeele, there is strict serializability (single-threaded and timestamps are unique). Postgres being concurrent should not force strict serializability. But should at least be robust and prevent race conditions and deadlocks when updating account balances.

## Tigerbeetle Flags and Features:
Tigerbeetle has various features that are implemented by setting certain flags on accounts and transfers. I only want the following to be implemented.

### Account Flags
- only the debits_must_not_exceed_credits and credits_must_not_exceed_debits flags should be implemented.
  - However they should be called require_credit_balance and require_debit_balance.
- There will be no history flag, but all accounts should have their historical balances accounted for. So the implementation would be similar to history=true. This is because of the strict immutability. Having history=false would mean updating a table.


### Transfer Flags
- only balancing_debit and balancing_credit flags should be implemented.
  - They should be called balance_debit_account and balance_credit_account.

- Two phase transfers and imports can be ignored.
- The default behavior of creating a batch of tranfers should be as if they are all "linked", meaning they all succeed or they all fail.

## Schema design

### Tables
There should be atleast the following three tables.
- accounts
- transfers
- account_balances


### Data types.
There isn't a perfect mapping from Tigerbeetle data types to Postgres data types so tradeoffs will have to be made.

#### Ids
- In tigerbeetle ids are uint128, I think it is pretty fitting to have ids as a Postgres UUID type since those are also uint128.

#### timestamp
- In tigerbeetle a timestamp is uint64 representing the number of microseconds since the unix epoch.
- Postgres has a native timestsamptz type that has microseconds as the smallest unit. This should be fitting.

#### Amounts
- There will be three fields representing amounts, the 'amount' field on tranfers, as well as debits_posted and credits_posted on account_balances.
- In Tigerbeetle, amounts are uint128 and postgres' largest integer type is a signed int64 (big int). This is pretty limiting so numeric(??,0) will have to do. We'd have to enforce that the number is not negative and not a fraction.

#### Ledger and Code
- In Tigerbeetle ledgers are uint32 and codes are uint16.
- I am thinking that a ledger can be int (must be positive). This gives us 2^31-1 ledgers.
- For codes, at first glance smallint makes sense when looking to make it tigerbeetle like, but for say accounts, there is already a standard for "chart of accounts" where account codes are often 3, 5, or even 7 digit codes. See here: https://www.accountingcoach.com/chart-of-accounts/explanation - So I am compelled to make codes numeric(5,0).


#### User Data
- I don't know if pgledger NEEDS user_data_128, user_data_64, and user_data_32 fields. 
- In the tigerbeetle docs, they often mention that user_data_128 can represent an external id and the user_data_64 can often represent a different timestamp. So that had me considering an external_id UUID and external_timestamp timestamptz type.
- But also a simple metadata JSONB field would be most flexible. I guess it depends on the potential memory usage of JSONB versus UUID and timestamptz.


# Performance
pgledger is not meant to be nearly as performant as Tigerbeetle. Tigerbeetle only exists because you couldn't realistically get the same kind of performance from a general purpose database.

Tigerbeetle advertises 100K-500K TPS on their homepage. If pgledger can achieve atleast a tenth of that speed that would be pretty impressive.

Obviously hardware matters for performance. Tigerbeetle docs says that a replica requires atleast 6GiB of RAM and 1-2 CPU Cores.

That should be considered when benchmarking.

## Indexes
- Indexes should be considered for query performance and enforcing relationships, but the overhead for write throughput should also be considered.
- Other data structures besides btree can be considered if it makes sense.

# Interface
Being that this is a Postgres Trusted Language Extension, many of these extensions come with 
easy to use functions so this library should do the same.

Tigerbeetle is strictly functions only and has no query language.

I think it makes sense that there is at least create_transfers() and create_accounts() functions.
Perhaps even a singular form. create_account() and create_tranfer().

Other tigerbeetle-like functions can be considered as well such as lookup_xxxx(), get_account_xxx(), and query_xxx().


# Supabase
The supabase project directory is used for sandboxing.


