#!/usr/bin/env bash
# benchmark.sh — Queue buffer bottleneck finder.
#
# Finds the ceiling of:
#   1. PostgreSQL raw insert capacity (direct, no queue)
#   2. RabbitMQ max publish rate
#   3. Worker max drain rate (WORKER_CONCURRENCY tuning)
#
# Usage:
#   ./scripts/benchmark.sh
#
# Required env vars:
#   QUEUE_IP     public IP of queue server
#   RABBIT_PASS  RabbitMQ password
#
# Optional:
#   DB_IP        public IP of DB server (for direct DB test)
#   DB_PASS      PostgreSQL password
set -euo pipefail

QUEUE_IP="${QUEUE_IP:-}"
RABBIT_PASS="${RABBIT_PASS:-}"
DB_IP="${DB_IP:-}"
DB_PASS="${DB_PASS:-}"
RABBIT_USER="${RABBIT_USER:-admin}"
QUEUE_NAME="events"
DURATION="${DURATION:-30}"

# ── helpers ───────────────────────────────────────────────────────────────────
hr()      { echo ""; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }
section() { hr; printf "  %s\n" "$1"; hr; echo ""; }
ts()      { date '+%H:%M:%S'; }

if [[ -z "$QUEUE_IP" || -z "$RABBIT_PASS" ]]; then
  echo "ERROR: Set required env vars:"
  echo "  export QUEUE_IP=\$(pulumi stack output queuePublicIp)"
  echo "  export RABBIT_PASS=\$(pulumi stack output --show-secrets rabbitmqAmqpUrl | sed 's/amqp:\/\/admin://;s/@.*//')"
  exit 1
fi

RABBIT_URL="amqp://${RABBIT_USER}:${RABBIT_PASS}@${QUEUE_IP}:5672"

# Install dependencies
python3 -c "import pika" 2>/dev/null        || pip3 install pika -q
python3 -c "import psycopg2" 2>/dev/null    || pip3 install psycopg2-binary -q

# ── helper: get queue depth ───────────────────────────────────────────────────
queue_depth() {
  curl -s -u "${RABBIT_USER}:${RABBIT_PASS}" \
    "http://${QUEUE_IP}:15672/api/queues/%2F/${QUEUE_NAME}" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('messages',0))" 2>/dev/null || echo "?"
}

drain_rate() {
  curl -s -u "${RABBIT_USER}:${RABBIT_PASS}" \
    "http://${QUEUE_IP}:15672/api/queues/%2F/${QUEUE_NAME}" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(round(d.get('message_stats',{}).get('ack_details',{}).get('rate',0),1))" 2>/dev/null || echo "?"
}

# ── helper: flush queue ───────────────────────────────────────────────────────
flush_queue() {
  curl -s -u "${RABBIT_USER}:${RABBIT_PASS}" \
    -X DELETE "http://${QUEUE_IP}:15672/api/queues/%2F/${QUEUE_NAME}/contents" >/dev/null 2>&1 || true
  sleep 2
}

# ── helper: publish N messages at rate R ─────────────────────────────────────
publish_messages() {
  local TOTAL="$1"
  local RATE="$2"
  python3 - <<EOF
import pika, json, time, sys

RABBIT_URL = "$RABBIT_URL"
QUEUE_NAME = "$QUEUE_NAME"
TOTAL      = $TOTAL
RATE       = $RATE

params = pika.URLParameters(RABBIT_URL)
params.socket_timeout = 10
conn = pika.BlockingConnection(params)
ch   = conn.channel()
ch.queue_declare(queue=QUEUE_NAME, durable=True)

interval  = 1.0 / RATE
published = 0
start     = time.time()

for i in range(TOTAL):
    ch.basic_publish(
        exchange='',
        routing_key=QUEUE_NAME,
        body=json.dumps({"event_type": "benchmark", "index": i}),
        properties=pika.BasicProperties(delivery_mode=2)
    )
    published += 1
    expected = start + (published / RATE)
    now = time.time()
    if expected > now:
        time.sleep(expected - now)

elapsed = time.time() - start
conn.close()
print(f"Published {published:,} messages in {elapsed:.1f}s ({published/elapsed:.0f} msg/sec avg)")
EOF
}

# ── helper: set worker concurrency live ──────────────────────────────────────
set_worker_concurrency() {
  local N="$1"
  ssh -o StrictHostKeyChecking=no root@"${QUEUE_IP}" \
    "docker exec worker kill -USR1 1 2>/dev/null || true; \
     docker exec -e WORKER_CONCURRENCY=${N} worker sh -c 'echo WORKER_CONCURRENCY=${N}' 2>/dev/null || true" 2>/dev/null || true
}

# ── Phase 1: Direct DB ceiling ────────────────────────────────────────────────
section "Phase 1 — Direct DB insert ceiling ($(ts))"

if [[ -z "$DB_IP" || -z "$DB_PASS" ]]; then
  echo "  Skipped — set DB_IP and DB_PASS to run direct DB test."
  echo "    export DB_IP=\$(pulumi stack output dbPublicIp)"
  echo "    export DB_PASS=\$(pulumi stack output --show-secrets postgresUrl | sed 's|postgresql://appuser:||;s|@.*||')"
  DB_CEILING="(skipped)"
else
  # Open SSH tunnel: Mac → internet → DB server → localhost:5432
  # Same path a real app would use — fair comparison with RabbitMQ test
  echo "  Opening SSH tunnel to DB (Mac → internet → DB server)..."
  ssh-keygen -R "${DB_IP}" 2>/dev/null || true
  pkill -f "15432:localhost:5432" 2>/dev/null || true; sleep 1
  ssh -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes \
      -fNT -L 15432:localhost:5432 root@"${DB_IP}"
  sleep 2
  echo "  Testing raw PostgreSQL insert capacity over internet (via SSH tunnel)..."
  echo "  Progressive concurrency: 10 → 50 → 100 → 200 connections"
  echo ""

  DB_CEILING=0
  PEAK_CONCURRENCY=0

  for CONC in 10 50 100 200; do
    OPS=$(python3 - <<PYEOF 2>/dev/null || echo 0
import psycopg2, threading, time

DSN      = "postgresql://appuser:${DB_PASS}@localhost:15432/appdb"
DURATION = $DURATION
CONC     = $CONC
results  = []
stop     = threading.Event()

def worker():
    conn = psycopg2.connect(DSN)
    conn.autocommit = True
    cur = conn.cursor()
    ops = 0
    while not stop.is_set():
        cur.execute("INSERT INTO events (event_type, payload) VALUES (%s, %s)",
                    ("benchmark", '{"direct": true}'))
        ops += 1
    results.append(ops)
    conn.close()

threads = [threading.Thread(target=worker) for _ in range(CONC)]
for t in threads: t.start()
time.sleep(DURATION)
stop.set()
for t in threads: t.join()
print(round(sum(results) / DURATION, 1))
PYEOF
)

    printf "    %4s connections → %s inserts/sec\n" "$CONC" "$OPS"
    if python3 -c "exit(0 if float('${OPS:-0}') > float('${DB_CEILING:-0}') else 1)" 2>/dev/null; then
      DB_CEILING=$OPS
      PEAK_CONCURRENCY=$CONC
    else
      echo "    Plateau reached at ${PEAK_CONCURRENCY} connections → bottleneck found"
      break
    fi
  done

  # Close SSH tunnel
  pkill -f "ssh.*15432:localhost:5432" 2>/dev/null || true
  echo ""
  echo "  DB ceiling: ${DB_CEILING} inserts/sec @ ${PEAK_CONCURRENCY} connections"
fi

# ── Phase 2: RabbitMQ publish ceiling ────────────────────────────────────────
section "Phase 2 — RabbitMQ publish ceiling ($(ts))"
echo "  Progressive publish rate: 1000 → 5000 → 10000 → 20000 → 50000 msg/sec"
echo ""

flush_queue

PREV_RATE=0
MQ_CEILING=0

for RATE in 1000 5000 10000 20000 50000; do
  TOTAL=$(( RATE * DURATION ))
  START=$(date +%s)

  OUTPUT=$(python3 - <<EOF 2>/dev/null
import pika, json, time

RABBIT_URL = "$RABBIT_URL"
QUEUE_NAME = "$QUEUE_NAME"
TOTAL      = $TOTAL
RATE       = $RATE

params = pika.URLParameters(RABBIT_URL)
params.socket_timeout = 10
conn = pika.BlockingConnection(params)
ch   = conn.channel()
ch.queue_declare(queue=QUEUE_NAME, durable=True)

published = 0
start     = time.time()
for i in range(TOTAL):
    ch.basic_publish(
        exchange='',
        routing_key=QUEUE_NAME,
        body=json.dumps({"event_type": "bench", "index": i}),
        properties=pika.BasicProperties(delivery_mode=2)
    )
    published += 1
    expected = start + (published / RATE)
    now = time.time()
    if expected > now:
        time.sleep(expected - now)

elapsed = time.time() - start
conn.close()
actual_rate = round(published / elapsed, 0)
print(actual_rate)
EOF
)
  END=$(date +%s)
  ELAPSED=$(( END - START ))
  ACTUAL="${OUTPUT:-0}"

  printf "    %5s msg/sec requested → %s msg/sec actual  (%ss)\n" "$RATE" "$ACTUAL" "$ELAPSED"

  # Check if actual rate is within 10% of requested (saturated = can't keep up)
  if python3 -c "exit(0 if float('${ACTUAL:-0}') >= float('$RATE') * 0.9 else 1)" 2>/dev/null; then
    MQ_CEILING=$ACTUAL
  else
    echo "    RabbitMQ saturated — ceiling is ~${MQ_CEILING} msg/sec"
    break
  fi

  flush_queue
done

# ── Phase 3: Worker drain ceiling ────────────────────────────────────────────
section "Phase 3 — Worker drain ceiling ($(ts))"
echo "  Floods queue with 100,000 messages then watches how fast worker drains."
echo "  (WORKER_CONCURRENCY=${WORKER_CONCURRENCY:-10} — change via pulumi config)"
echo ""

flush_queue

# Publish 100k messages as fast as possible
publish_messages 100000 20000
echo ""

START_DEPTH=$(queue_depth)
echo "  Queue after flood: ${START_DEPTH} messages"
echo "  Watching drain every 5s..."
echo ""

START_TIME=$(date +%s)
PREV_DEPTH=$START_DEPTH

for i in $(seq 1 20); do
  sleep 5
  DEPTH=$(queue_depth)
  RATE=$(drain_rate)
  ELAPSED=$(( ($(date +%s) - START_TIME) ))
  printf "  [%3ds] depth: %-8s | drain: %s msg/sec\n" "$ELAPSED" "$DEPTH" "$RATE"
  [ "${DEPTH}" = "0" ] && echo "" && echo "  Queue empty — all messages written to DB." && break
done

ELAPSED_TOTAL=$(( $(date +%s) - START_TIME ))
PEAK_DRAIN=0
PEAK_CONC="${WORKER_CONCURRENCY:-10}"
if [ "$ELAPSED_TOTAL" -gt 0 ] && [ "$START_DEPTH" != "?" ]; then
  PEAK_DRAIN=$(python3 -c "print(round(int('${START_DEPTH:-0}')/${ELAPSED_TOTAL},1))" 2>/dev/null || echo "?")
fi
echo ""
echo "  Average drain: ${PEAK_DRAIN} msg/sec over ${ELAPSED_TOTAL}s"

flush_queue

# ── Results ───────────────────────────────────────────────────────────────────
section "Bottleneck Results ($(ts))"

echo "  ┌──────────────────────────────────────────────────────┐"
printf "  │  DB ceiling (direct inserts)  : %-20s│\n" "${DB_CEILING} inserts/sec"
printf "  │  RabbitMQ publish ceiling     : %-20s│\n" "~${MQ_CEILING} msg/sec"
printf "  │  Worker drain rate            : %-20s│\n" "~${PEAK_DRAIN} msg/sec (CONCURRENCY=${PEAK_CONC})"
echo "  ├──────────────────────────────────────────────────────┤"
echo "  │  Hardware: cx23 (2 vCPU / 4GB RAM)                  │"
echo "  │  Queue: RabbitMQ 4.2.4 | DB: PostgreSQL 18.3 Alpine │"
echo "  └──────────────────────────────────────────────────────┘"
echo ""
echo "  RabbitMQ UI: http://${QUEUE_IP}:15672  (admin / ${RABBIT_PASS})"
