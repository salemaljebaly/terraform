#!/usr/bin/env bash
set -euo pipefail

HOST="${1:-127.0.0.1}"
PORT="${PORT:-5433}"
DB="${DB:-yugabyte}"
USER_NAME="${USER_NAME:-yugabyte}"
CLIENTS="${CLIENTS:-32}"
THREADS="${THREADS:-8}"
DURATION="${DURATION:-120}"
SCALE="${SCALE:-50}"

echo "Running pgbench against ${HOST}:${PORT}/${DB}"
echo "clients=${CLIENTS} threads=${THREADS} duration=${DURATION}s scale=${SCALE}"

pgbench -h "${HOST}" -p "${PORT}" -U "${USER_NAME}" -i -s "${SCALE}" "${DB}"
pgbench -h "${HOST}" -p "${PORT}" -U "${USER_NAME}" -c "${CLIENTS}" -j "${THREADS}" -T "${DURATION}" "${DB}"
