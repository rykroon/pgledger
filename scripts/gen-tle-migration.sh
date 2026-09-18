#!/usr/bin/env bash
# Regenerates the pg_tle install migration from pgledger.control + pgledger--0.0.1.sql.
# Run this after any edit to the extension script, then `supabase db reset`.
#
# `dbdev add` names its own output file and tacks an unqualified `create extension` onto the
# end. That would put pgledger in the default creation schema, so the tail is stripped here and
# the schema-aware CREATE EXTENSION is left to its own migration.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="$(find "$root/supabase/migrations" -name '*_install_pgledger_tle.sql' | head -1)"
[ -n "$target" ] || { echo "no *_install_pgledger_tle.sql migration to refresh" >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

dbdev add --output-path "$tmp" path --directory "$root" >/dev/null

generated="$(find "$tmp" -name '*_install.sql' -maxdepth 1 | head -1)"
[ -n "$generated" ] || { echo "dbdev add produced no migration" >&2; exit 1; }

sed -e '/^-- Delete existing extension if installed$/d' \
    -e '/^drop extension if exists /d' \
    -e '/^-- Create the extension$/d' \
    -e '/^create extension "pgledger" version /d' \
    "$generated" > "$target"

grep -q 'pgtle.install_extension' "$target" || { echo "install_extension call missing" >&2; exit 1; }
! grep -qi '^create extension' "$target" || { echo "unqualified create extension survived" >&2; exit 1; }

echo "wrote $target"
