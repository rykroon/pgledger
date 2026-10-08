#!/usr/bin/env bash
# Starts a throwaway Postgres container with pgledger installed as a regular extension, then
# runs the Go benchmark against it. All arguments are passed through to the benchmark:
#
#   bench/run.sh -clients 32 -batch 50 -hot-ratio 0.5
#
# Environment:
#   PG_IMAGE   postgres image (default postgres:17)
#   PG_PORT    host port (default 54329)
#   PG_CPUS    container CPU limit (default 2, TigerBeetle's replica minimum)
#   PG_MEMORY  container memory limit (default 6g, TigerBeetle's replica minimum)
#   PG_ARGS    extra postgres flags, e.g. "-c synchronous_commit=off"
#   KEEP=1     leave the container running afterwards
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name=pgledger-bench
image="${PG_IMAGE:-postgres:17}"
port="${PG_PORT:-54329}"
extdir=/usr/share/postgresql/17/extension

cleanup() {
    if [ "${KEEP:-0}" = 1 ]; then
        echo "container $name left running on port $port (docker rm -f $name to remove)" >&2
    else
        docker rm -f "$name" >/dev/null 2>&1 || true
    fi
}

docker rm -f "$name" >/dev/null 2>&1 || true
trap cleanup EXIT

# The extension files are bind-mounted, so SQL edits take effect on the next run.
# shellcheck disable=SC2086
docker run -d --name "$name" \
    --cpus "${PG_CPUS:-2}" --memory "${PG_MEMORY:-6g}" --shm-size 1g \
    -p "$port:5432" \
    -e POSTGRES_PASSWORD=postgres \
    -v "$root/pgledger.control:$extdir/pgledger.control:ro" \
    -v "$root/pgledger--0.0.1.sql:$extdir/pgledger--0.0.1.sql:ro" \
    "$image" \
    -c max_connections=300 \
    -c shared_buffers=1536MB \
    -c effective_cache_size=4GB \
    -c wal_buffers=64MB \
    -c max_wal_size=4GB \
    -c checkpoint_timeout=15min \
    ${PG_ARGS:-} >/dev/null

# The entrypoint's init server only listens on the unix socket, so probing TCP waits for the
# real server.
for _ in $(seq 1 60); do
    if docker exec "$name" pg_isready -q -h 127.0.0.1 -U postgres; then
        break
    fi
    sleep 1
done
docker exec "$name" pg_isready -q -h 127.0.0.1 -U postgres \
    || { echo "postgres did not become ready" >&2; docker logs "$name" >&2; exit 1; }

cd "$root/bench"
go run . -dsn "postgres://postgres:postgres@localhost:$port/postgres" "$@"
