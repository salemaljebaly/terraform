#!/usr/bin/env bash
# benchmark-k6.sh — YugabyteDB bottleneck finder (progressive load test).
#
# Uses Python asyncpg inside K8s Jobs (ARM64 native, no custom image needed).
# Equivalent to k6 load testing but works on all architectures.
#
# Workloads:
#   insert — pure UUID inserts (max write TPS, no hot rows)
#   mixed  — 70% inserts / 30% reads (real app simulation)
#
# Progressive load: 50 -> 100 -> 200 -> 400 concurrent connections
# Stops when TPS growth < 5% (plateau = bottleneck found)
#
# Usage:
#   export KUBECONFIG=$(pwd)/kubeconfig.yaml
#   ./scripts/benchmark-k6.sh
#
# Tuning (env vars):
#   STEP_DURATION  seconds per step (default: 60)
#   MAX_WAIT       seconds to wait for 10 tservers (default: 900)
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-$(pwd)/kubeconfig.yaml}"
export KUBECONFIG

STEP_DURATION="${STEP_DURATION:-60}"
MAX_WAIT="${MAX_WAIT:-900}"
BENCH_NS="yugabyte"
YB_HOST="yb-tservers.yugabyte.svc.cluster.local"
YB_PORT="5433"
VU_STEPS=(50 100 200 400)

# ── helpers ───────────────────────────────────────────────────────────────────
hr()      { echo ""; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }
section() { hr; printf "  %s\n" "$1"; hr; echo ""; }
ts()      { date '+%H:%M:%S'; }

cleanup() {
  echo ""
  echo "==> Cleaning up benchmark jobs..."
  kubectl delete jobs -n "$BENCH_NS" -l bench=load-bottleneck --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete configmap load-script -n "$BENCH_NS" --ignore-not-found=true >/dev/null 2>&1 || true
  echo "==> Scaling tservers back to 3..."
  helm upgrade yugabyte yugabytedb/yugabyte \
    --namespace "$BENCH_NS" --reuse-values \
    --set replicas.tserver=3 --wait=false 2>/dev/null || true
  echo "    Autoscaler will reclaim idle nodes in ~5 min."
}
trap cleanup EXIT

# ── create Python load script as ConfigMap ────────────────────────────────────
deploy_script() {
  kubectl delete configmap load-script -n "$BENCH_NS" --ignore-not-found=true >/dev/null 2>&1 || true

  kubectl create configmap load-script -n "$BENCH_NS" \
    --from-literal=load.py='
import asyncio, asyncpg, os, time, random, string

HOST     = os.environ.get("YB_HOST", "localhost")
PORT     = int(os.environ.get("YB_PORT", "5433"))
VUS      = int(os.environ.get("VUS", "100"))
DURATION = int(os.environ.get("DURATION", "60"))
WORKLOAD = os.environ.get("WORKLOAD", "insert")

async def setup(conn):
    await conn.execute("""
        CREATE TABLE IF NOT EXISTS load_test (
            id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            worker_id  INT  NOT NULL,
            score      INT  NOT NULL,
            payload    TEXT NOT NULL,
            created_at TIMESTAMPTZ DEFAULT NOW()
        )
    """)

async def worker(pool, worker_id, results, stop_event):
    ops = 0
    latencies = []
    async with pool.acquire() as conn:
        while not stop_event.is_set():
            t0 = time.monotonic()
            try:
                if WORKLOAD == "insert" or (WORKLOAD == "mixed" and random.random() < 0.7):
                    score = random.randint(0, 10000)
                    payload = "w" + str(worker_id) + "_" + "".join(random.choices(string.ascii_lowercase, k=8))
                    await conn.execute(
                        "INSERT INTO load_test (worker_id, score, payload) VALUES ($1, $2, $3)",
                        worker_id, score, payload
                    )
                else:
                    min_score = random.randint(0, 5000)
                    await conn.fetch(
                        "SELECT id, score FROM load_test WHERE score > $1 LIMIT 20",
                        min_score
                    )
                ops += 1
                latencies.append((time.monotonic() - t0) * 1000)
            except Exception:
                pass
    results[worker_id] = (ops, latencies)

async def main():
    dsn = f"postgresql://yugabyte@{HOST}:{PORT}/yugabyte"
    pool = await asyncpg.create_pool(dsn, min_size=1, max_size=VUS + 5)

    # Setup table
    async with pool.acquire() as conn:
        await setup(conn)

    print(f"Starting {VUS} workers | workload={WORKLOAD} | duration={DURATION}s")

    stop_event = asyncio.Event()
    results = {}

    start = time.monotonic()
    tasks = [asyncio.create_task(worker(pool, i, results, stop_event)) for i in range(VUS)]

    await asyncio.sleep(DURATION)
    stop_event.set()
    await asyncio.gather(*tasks, return_exceptions=True)
    elapsed = time.monotonic() - start

    total_ops = sum(r[0] for r in results.values())
    all_latencies = sorted([l for r in results.values() for l in r[1]])

    ops_per_sec = round(total_ops / elapsed, 1)
    p50 = all_latencies[int(len(all_latencies) * 0.50)] if all_latencies else 0
    p95 = all_latencies[int(len(all_latencies) * 0.95)] if all_latencies else 0
    p99 = all_latencies[int(len(all_latencies) * 0.99)] if all_latencies else 0

    print(f"ops_per_sec={ops_per_sec}")
    print(f"total_ops={total_ops}")
    print(f"p50_ms={round(p50,1)}")
    print(f"p95_ms={round(p95,1)}")
    print(f"p99_ms={round(p99,1)}")
    print(f"elapsed_s={round(elapsed,1)}")

    await pool.close()

asyncio.run(main())
' >/dev/null

  echo "  Load script uploaded."
}

# ── run single load step ──────────────────────────────────────────────────────
run_step() {
  local JOB_NAME="$1"
  local VUS="$2"
  local WORKLOAD="$3"

  kubectl delete job "$JOB_NAME" -n "$BENCH_NS" --ignore-not-found=true >/dev/null 2>&1 || true

  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${BENCH_NS}
  labels:
    bench: load-bottleneck
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      volumes:
        - name: load-script
          configMap:
            name: load-script
      containers:
        - name: loader
          image: python:3.11-slim
          command: ["sh", "-c"]
          args:
            - "pip install asyncpg -q && python /scripts/load.py"
          env:
            - name: YB_HOST
              value: "${YB_HOST}"
            - name: YB_PORT
              value: "${YB_PORT}"
            - name: VUS
              value: "${VUS}"
            - name: DURATION
              value: "${STEP_DURATION}"
            - name: WORKLOAD
              value: "${WORKLOAD}"
          volumeMounts:
            - name: load-script
              mountPath: /scripts
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
EOF

  # Wait for pod to start
  for i in $(seq 1 60); do
    PHASE=$(kubectl get pods -n "$BENCH_NS" -l "job-name=${JOB_NAME}" \
      -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Pending")
    [[ "$PHASE" == "Running" || "$PHASE" == "Succeeded" ]] && break
    sleep 5
  done

  kubectl wait --for=condition=Complete job/"$JOB_NAME" -n "$BENCH_NS" \
    --timeout=$(( STEP_DURATION + 120 ))s >/dev/null 2>&1 || \
  kubectl wait --for=condition=Failed   job/"$JOB_NAME" -n "$BENCH_NS" \
    --timeout=10s >/dev/null 2>&1 || true

  local POD LOGS OPS P95 P99
  POD=$(kubectl get pods -n "$BENCH_NS" -l "job-name=${JOB_NAME}" \
    -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || echo "")

  if [[ -n "$POD" ]]; then
    LOGS=$(kubectl logs -n "$BENCH_NS" "$POD" 2>/dev/null || echo "")
    OPS=$(echo "$LOGS" | grep "ops_per_sec=" | grep -oE '[0-9]+\.[0-9]+' || echo "0")
    P95=$(echo "$LOGS" | grep "p95_ms="     | grep -oE '[0-9]+\.[0-9]+' || echo "0")
    P99=$(echo "$LOGS" | grep "p99_ms="     | grep -oE '[0-9]+\.[0-9]+' || echo "0")
    printf "    %4s VUs | ops/sec: %-8s | p95: %sms | p99: %sms\n" \
      "$VUS" "$OPS" "$P95" "$P99" >&2
  else
    printf "    %4s VUs | (no result)\n" "$VUS" >&2
    OPS="0"
  fi

  kubectl delete job "$JOB_NAME" -n "$BENCH_NS" --ignore-not-found=true >/dev/null 2>&1 || true
  echo "${OPS:-0}"
}

# ── progressive load test ─────────────────────────────────────────────────────
run_progressive() {
  local LABEL="$1"
  local WORKLOAD="$2"
  local PREV_OPS=0
  local PEAK_OPS=0
  local PEAK_VUS=0
  local -a RESULTS=()

  echo "  Workload: ${WORKLOAD} | steps: ${VU_STEPS[*]} VUs x ${STEP_DURATION}s each" >&2
  echo "" >&2

  for VUS in "${VU_STEPS[@]}"; do
    local OPS
    OPS=$(run_step "${LABEL}-v${VUS}" "$VUS" "$WORKLOAD")
    RESULTS+=("${VUS}:${OPS}")

    if python3 -c "exit(0 if float('${OPS}') > float('${PEAK_OPS}') else 1)" 2>/dev/null; then
      PEAK_OPS=$OPS
      PEAK_VUS=$VUS
    fi

    # Stop if growth < 5% vs previous step
    if [[ "$PREV_OPS" != "0" ]]; then
      if python3 -c "exit(0 if float('${OPS}') - float('${PREV_OPS}') < float('${PREV_OPS}') * 0.05 else 1)" 2>/dev/null; then
        echo "" >&2
        echo "  Plateau at ${PEAK_VUS} VUs -> ${PEAK_OPS} ops/sec (growth <5%, bottleneck found)" >&2
        break
      fi
    fi
    PREV_OPS=$OPS
  done

  echo "" >&2
  echo "  Summary:" >&2
  for R in "${RESULTS[@]}"; do
    printf "    %4s VUs -> %s ops/sec\n" "$(echo $R|cut -d: -f1)" "$(echo $R|cut -d: -f2)" >&2
  done

  echo "${PEAK_OPS}:${PEAK_VUS}"
}

# ── Phase 1: Cluster state ────────────────────────────────────────────────────
section "Phase 1 — Cluster state ($(ts))"
kubectl get nodes -o wide
echo ""
kubectl get pods -n "$BENCH_NS" -l app=yb-tserver -o wide
echo ""
WORKER_COUNT_BEFORE=$(kubectl get nodes \
  --selector='!node-role.kubernetes.io/control-plane' --no-headers | wc -l | tr -d ' ')
echo "  Workers: ${WORKER_COUNT_BEFORE}"

# ── Phase 2: Upload script ────────────────────────────────────────────────────
section "Phase 2 — Uploading load script"
deploy_script

# ── Phase 3: Bottleneck @ 3 tservers ─────────────────────────────────────────
section "Phase 3 — Bottleneck test @ 3 tservers ($(ts))"

echo "  [3a] Pure inserts (max write TPS):" >&2
R3I=$(run_progressive "b3-insert" "insert")
PEAK_3_INSERT=$(echo "$R3I" | cut -d: -f1)
PEAK_3_INSERT_VUS=$(echo "$R3I" | cut -d: -f2)

echo "" >&2
echo "  [3b] Mixed 70/30 (real app):" >&2
R3M=$(run_progressive "b3-mixed" "mixed")
PEAK_3_MIXED=$(echo "$R3M" | cut -d: -f1)

# ── Phase 4: Scale tservers 3->10 ─────────────────────────────────────────────
section "Phase 4 — Scaling tservers 3 -> 10 ($(ts))"
echo "  Autoscaler provisions new CAX11 nodes..."
echo ""

helm upgrade yugabyte yugabytedb/yugabyte \
  --namespace "$BENCH_NS" --reuse-values \
  --set replicas.tserver=10 --timeout 5m --wait=false

echo "==> Watching (max ${MAX_WAIT}s)..."
echo ""
START_TS=$SECONDS
while true; do
  ELAPSED=$(( SECONDS - START_TS ))
  [[ $ELAPSED -gt $MAX_WAIT ]] && echo "  WARN: Timed out." && break

  READY=$(kubectl get pods -n "$BENCH_NS" -l app=yb-tserver \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')
  PENDING=$(kubectl get pods -n "$BENCH_NS" -l app=yb-tserver \
    --field-selector=status.phase=Pending \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')
  NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  WORKERS=$(kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')

  printf "  [%3ds] nodes: %d (workers: %d) | tservers: %s/10  pending: %s\n" \
    "$ELAPSED" "$NODES" "$WORKERS" "$READY" "$PENDING"

  [[ "$READY" -ge 10 ]] && echo "" && echo "  All 10 tservers Running." && break
  sleep 15
done

WORKER_COUNT_AFTER=$(kubectl get nodes \
  --selector='!node-role.kubernetes.io/control-plane' --no-headers | wc -l | tr -d ' ')

# ── Phase 5: Bottleneck @ 10 tservers ────────────────────────────────────────
section "Phase 5 — Bottleneck test @ 10 tservers ($(ts))"

echo "  [5a] Pure inserts (max write TPS):" >&2
R10I=$(run_progressive "b10-insert" "insert")
PEAK_10_INSERT=$(echo "$R10I" | cut -d: -f1)
PEAK_10_INSERT_VUS=$(echo "$R10I" | cut -d: -f2)

echo "" >&2
echo "  [5b] Mixed 70/30 (real app):" >&2
R10M=$(run_progressive "b10-mixed" "mixed")
PEAK_10_MIXED=$(echo "$R10M" | cut -d: -f1)

# ── Phase 6: Results ──────────────────────────────────────────────────────────
section "Results — Cluster Bottleneck ($(ts))"

INSERT_SPEEDUP=$(python3 -c "b=float('${PEAK_3_INSERT}'); s=float('${PEAK_10_INSERT}'); print(round(s/b,2) if b>0 else 'N/A')")
MIXED_SPEEDUP=$(python3  -c "b=float('${PEAK_3_MIXED}');  s=float('${PEAK_10_MIXED}');  print(round(s/b,2) if b>0 else 'N/A')")

printf "  %-32s %-18s %s\n" ""                    "3 tservers"      "10 tservers"
printf "  %-32s %-18s %s\n" "-------------------"  "------------"    "------------"
printf "  %-32s %-18s %s\n" "Peak insert ops/sec:"  "$PEAK_3_INSERT"  "$PEAK_10_INSERT"
printf "  %-32s %-18s %s\n" "Peak mixed ops/sec:"   "$PEAK_3_MIXED"   "$PEAK_10_MIXED"
printf "  %-32s %-18s %s\n" "Workers:"              "$WORKER_COUNT_BEFORE" "$WORKER_COUNT_AFTER"
echo ""
printf "  Insert speedup : ${INSERT_SPEEDUP}x\n"
printf "  Mixed speedup  : ${MIXED_SPEEDUP}x\n"
echo ""
printf "  Bottleneck VUs (inserts @ 10 tservers): ${PEAK_10_INSERT_VUS}\n"
echo "  Adding more VUs beyond this = CPU saturated on CAX11 nodes"
echo ""
echo "  To increase TPS: upgrade to CAX31 (8 vCPU) or add more worker nodes"
