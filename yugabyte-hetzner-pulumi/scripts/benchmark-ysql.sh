#!/usr/bin/env bash
# YugabyteDB TPS benchmark using ysql_bench (bundled with YugabyteDB).
#
# ysql_bench is YugabyteDB's fork of pgbench. Key differences vs plain pgbench:
#   --max-tries   retries serialization errors (common in distributed SQL)
#   --no-vacuum   skips VACUUM (YugabyteDB does not use PostgreSQL VACUUM)
#   --protocol=prepared  uses prepared statements for lower per-query overhead
#
# Usage:
#   ./benchmark-ysql.sh [HOST]
#   CLIENTS=64 THREADS=16 DURATION=300 ./benchmark-ysql.sh 127.0.0.1
#
# Run this ON node-1 (ssh root@<publicIpv4>), not from your local machine,
# so ysql_bench talks to the DB over loopback with no network overhead.
set -euo pipefail

HOST="${1:-127.0.0.1}"
PORT="${PORT:-5433}"
DB="${DB:-yugabyte}"
USER_NAME="${USER_NAME:-yugabyte}"
CLIENTS="${CLIENTS:-32}"
THREADS="${THREADS:-8}"
DURATION="${DURATION:-120}"
SCALE="${SCALE:-50}"    # 1 unit ≈ 100k rows; scale=50 ≈ 5M rows ≈ 2.5 GB
MAX_TRIES="${MAX_TRIES:-10}"
WARMUP="${WARMUP:-30}"

# ysql_bench is installed alongside YugabyteDB binaries.
YSQL_BENCH="${YSQL_BENCH:-/opt/yugabyte/postgres/bin/ysql_bench}"

if [[ ! -x "${YSQL_BENCH}" ]]; then
  echo "ERROR: ysql_bench not found at ${YSQL_BENCH}" >&2
  echo "Run this script on a YugabyteDB node, or set YSQL_BENCH=/path/to/ysql_bench" >&2
  exit 1
fi

echo "=== YugabyteDB TPS Benchmark (ysql_bench) ==="
echo "host=${HOST}:${PORT}/${DB}"
echo "scale=${SCALE}  clients=${CLIENTS}  threads=${THREADS}"
echo "warmup=${WARMUP}s  duration=${DURATION}s  max_tries=${MAX_TRIES}"
echo ""

echo "--- [1/3] Init: loading data (scale=${SCALE}, ~$((SCALE * 100))k rows) ---"
"${YSQL_BENCH}" \
  -h "${HOST}" -p "${PORT}" -U "${USER_NAME}" \
  --no-vacuum \
  -i -s "${SCALE}" \
  "${DB}"

echo ""
echo "--- [2/3] Warmup: ${WARMUP}s (results discarded) ---"
"${YSQL_BENCH}" \
  -h "${HOST}" -p "${PORT}" -U "${USER_NAME}" \
  -c "${CLIENTS}" -j "${THREADS}" \
  -T "${WARMUP}" \
  --no-vacuum \
  --max-tries="${MAX_TRIES}" \
  --protocol=prepared \
  "${DB}" > /dev/null

echo ""
echo "--- [3/3] Run: ${DURATION}s ---"
"${YSQL_BENCH}" \
  -h "${HOST}" -p "${PORT}" -U "${USER_NAME}" \
  -c "${CLIENTS}" -j "${THREADS}" \
  -T "${DURATION}" \
  --no-vacuum \
  --max-tries="${MAX_TRIES}" \
  --protocol=prepared \
  -r \
  "${DB}"
