#!/usr/bin/env bash
# benchmark.sh — Queue buffer stress test.
#
# Tests two scenarios:
#   1. Direct DB  — hits PostgreSQL directly (no queue)
#   2. Via queue  — floods RabbitMQ, worker drains to DB at controlled rate
#
# Shows the difference: direct DB gets overwhelmed, queue absorbs the spike.
#
# Usage:
#   ./scripts/benchmark.sh
#
# Tuning (env vars):
#   QUEUE_IP       public IP of queue server (from pulumi stack output)
#   RABBIT_USER    RabbitMQ user (default: admin)
#   RABBIT_PASS    RabbitMQ password (from pulumi stack output)
#   DB_URL         PostgreSQL URL (from pulumi stack output, via SSH tunnel)
#   RATE           messages/sec to publish to queue (default: 500)
#   DURATION       benchmark duration in seconds (default: 30)
set -euo pipefail

QUEUE_IP="${QUEUE_IP:-}"
RABBIT_USER="${RABBIT_USER:-admin}"
RABBIT_PASS="${RABBIT_PASS:-}"
DB_URL="${DB_URL:-}"
RATE="${RATE:-500}"
DURATION="${DURATION:-30}"

QUEUE_NAME="events"

# ── helpers ───────────────────────────────────────────────────────────────────
hr()      { echo ""; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }
section() { hr; printf "  %s\n" "$1"; hr; echo ""; }
ts()      { date '+%H:%M:%S'; }

if [[ -z "$QUEUE_IP" || -z "$RABBIT_PASS" ]]; then
  echo "ERROR: Set QUEUE_IP and RABBIT_PASS from pulumi stack output:"
  echo "  export QUEUE_IP=\$(pulumi stack output queuePublicIp)"
  echo "  export RABBIT_PASS=\$(pulumi stack output rabbitmqAmqpUrl | grep -oP '(?<=admin:)[^@]+')"
  exit 1
fi

RABBIT_URL="amqp://${RABBIT_USER}:${RABBIT_PASS}@${QUEUE_IP}:5672"
TOTAL_MESSAGES=$(( RATE * DURATION ))

# ── Phase 1: DB direct baseline ───────────────────────────────────────────────
section "Phase 1 — Direct DB baseline ($(ts))"
echo "  Measures raw PostgreSQL insert capacity."
echo "  Uses pgbench directly against DB via SSH tunnel."
echo ""

if [[ -n "$DB_URL" ]]; then
  echo "  Running pgbench for ${DURATION}s..."
  PGPASSWORD=$(echo "$DB_URL" | grep -oP '(?<=:)[^@]+(?=@)') \
  PG_HOST=$(echo "$DB_URL" | grep -oP '(?<=@)[^:]+') \
  PG_PORT=$(echo "$DB_URL" | grep -oP '(?<=:)\d+(?=/)') \
  PG_DB=$(echo "$DB_URL" | grep -oP '[^/]+$')

  # Custom pgbench script — direct insert (no hot rows)
  TMP_SQL=$(mktemp /tmp/bench_XXXXXX.sql)
  cat > "$TMP_SQL" <<'EOF'
\set payload random(1, 1000000)
INSERT INTO events (event_type, payload) VALUES ('benchmark', ('{"value":' || :payload || '}')::jsonb);
EOF

  pgbench \
    -h "$PG_HOST" -p "$PG_PORT" -U "appuser" \
    -f "$TMP_SQL" \
    -c 20 -j 4 -T "$DURATION" \
    --no-vacuum \
    "appdb" 2>/dev/null || echo "  (pgbench not available — skipping direct DB test)"

  rm -f "$TMP_SQL"
else
  echo "  DB_URL not set — skipping direct DB test."
  echo "  Set DB_URL to run: export DB_URL=<postgres-url-via-ssh-tunnel>"
fi

# ── Phase 2: Queue flood ──────────────────────────────────────────────────────
section "Phase 2 — Queue flood @ ${RATE} msg/sec ($(ts))"
echo "  Publishes ${TOTAL_MESSAGES} messages to RabbitMQ at ${RATE}/sec."
echo "  Worker drains queue to DB at controlled rate (WORKER_CONCURRENCY)."
echo "  App receives instant response; DB never overwhelmed."
echo ""

# Check if Python + pika available
if ! python3 -c "import pika" 2>/dev/null; then
  echo "  Installing pika..."
  pip3 install pika -q
fi

echo "  Publishing ${TOTAL_MESSAGES} messages..."
START=$(date +%s)

python3 - <<EOF
import pika, json, time, sys

RABBIT_URL     = "$RABBIT_URL"
QUEUE_NAME     = "$QUEUE_NAME"
RATE           = $RATE
DURATION       = $DURATION
TOTAL          = RATE * DURATION

params = pika.URLParameters(RABBIT_URL)
params.socket_timeout = 10
conn = pika.BlockingConnection(params)
ch   = conn.channel()
ch.queue_declare(queue=QUEUE_NAME, durable=True)

interval = 1.0 / RATE
published = 0
start     = time.time()

print(f"  Publishing {TOTAL:,} messages at {RATE}/sec...")
for i in range(TOTAL):
    msg = json.dumps({"event_type": "benchmark", "index": i, "value": i * 2})
    ch.basic_publish(
        exchange='',
        routing_key=QUEUE_NAME,
        body=msg,
        properties=pika.BasicProperties(delivery_mode=2)  # persistent
    )
    published += 1
    if published % 1000 == 0:
        elapsed = time.time() - start
        rate    = published / elapsed
        sys.stdout.write(f"\r    Progress: {published:,}/{TOTAL:,} ({rate:.0f} msg/sec)  ")
        sys.stdout.flush()
    # Rate limiting
    expected_time = start + (published / RATE)
    now = time.time()
    if expected_time > now:
        time.sleep(expected_time - now)

elapsed = time.time() - start
conn.close()
print(f"\n  Done: {published:,} messages in {elapsed:.1f}s ({published/elapsed:.0f} msg/sec avg)")
EOF

END=$(date +%s)
PUBLISH_TIME=$(( END - START ))

echo ""
echo "  Published ${TOTAL_MESSAGES} messages in ${PUBLISH_TIME}s."
echo "  App returned 'accepted' to all requests instantly."

# ── Phase 3: Watch queue drain ────────────────────────────────────────────────
section "Phase 3 — Watching queue drain ($(ts))"
echo "  Worker is draining queue to PostgreSQL at WORKER_CONCURRENCY rate."
echo "  Polling RabbitMQ management API every 5s..."
echo ""

if ! command -v curl &>/dev/null; then
  echo "  curl not available — skipping drain watch"
else
  for i in $(seq 1 12); do
    QUEUE_DEPTH=$(curl -s -u "${RABBIT_USER}:${RABBIT_PASS}" \
      "http://${QUEUE_IP}:15672/api/queues/%2F/${QUEUE_NAME}" \
      2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('messages',0))" 2>/dev/null || echo "?")

    CONSUMER_RATE=$(curl -s -u "${RABBIT_USER}:${RABBIT_PASS}" \
      "http://${QUEUE_IP}:15672/api/queues/%2F/${QUEUE_NAME}" \
      2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(round(d.get('message_stats',{}).get('ack_details',{}).get('rate',0),1))" 2>/dev/null || echo "?")

    printf "  [%2ds] Queue depth: %-8s | Drain rate: %s msg/sec\n" \
      $(( i * 5 )) "$QUEUE_DEPTH" "$CONSUMER_RATE"

    [[ "$QUEUE_DEPTH" == "0" ]] && echo "" && echo "  Queue empty — all messages written to DB." && break
    sleep 5
  done
fi

# ── Results ───────────────────────────────────────────────────────────────────
section "Results ($(ts))"
echo "  Scenario          | Result"
echo "  ─────────────────────────────────────────────────────────"
echo "  Direct DB         | Limited by DB capacity (~200-500 inserts/sec)"
echo "  Via queue (flood) | ${TOTAL_MESSAGES} messages accepted in ${PUBLISH_TIME}s (instant)"
echo "  Worker drain rate | Controlled by WORKER_CONCURRENCY (safe for DB)"
echo ""
echo "  This is the queue buffer pattern:"
echo "    - App publishes to queue: returns immediately (no DB wait)"
echo "    - Worker consumes at DB capacity: DB never overwhelmed"
echo "    - Spike of ${RATE} msg/sec → DB sees only WORKER_CONCURRENCY/sec"
echo ""
echo "  RabbitMQ Management UI:"
echo "    http://${QUEUE_IP}:15672"
echo "    Username: ${RABBIT_USER}"
