#!/usr/bin/env bash
# benchmark-yb.sh — Official YugabyteDB benchmark using ysql_bench.
#
# Uses the same yugabytedb/yugabyte image as the running cluster.
# ysql_bench is YugabyteDB's official pgbench fork with:
#   --max-tries   : retries serialization errors automatically
#   --no-vacuum   : skips VACUUM (YugabyteDB uses MVCC, no vacuum needed)
#   --protocol=prepared : prepared statements, lower per-query overhead
#
# Strategy:
#   1. Init schema (ysql_bench -i) — one-time, ~10 min for scale=50
#   2. Baseline TPS @ 3 tservers — one job per tserver, direct pod DNS
#   3. Scale tservers 3→10 — autoscaler provisions new nodes
#   4. Full-scale TPS @ 10 tservers
#   5. Report before/after comparison
#
# Usage:
#   export KUBECONFIG=$(pwd)/kubeconfig.yaml
#   ./scripts/benchmark-yb.sh
#
#   # Skip init if data already exists:
#   SKIP_INIT=true ./scripts/benchmark-yb.sh
#
# Tuning (env vars):
#   SCALE        pgbench scale factor (default: 50 → 5M rows, ~10 min init)
#   CLIENTS      total clients split across tservers (default: 64)
#   THREADS      total threads split across tservers (default: 16)
#   WARMUP       warmup seconds before benchmark (default: 30)
#   DURATION     benchmark seconds (default: 120)
#   MAX_TRIES    max retries per serialization conflict (default: 50)
#   SKIP_INIT    set to "true" to skip schema init (default: false)
#   MAX_WAIT     seconds to wait for 10 tservers ready (default: 900)
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-$(pwd)/kubeconfig.yaml}"
export KUBECONFIG

# Auto-detect image from running tserver so it always matches the cluster
YB_IMAGE=$(kubectl get pod -n yugabyte -l app=yb-tserver \
  -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || echo "yugabytedb/yugabyte:latest")
YSQL_BENCH="/home/yugabyte/postgres/bin/ysql_bench"

SCALE="${SCALE:-50}"
CLIENTS="${CLIENTS:-64}"
THREADS="${THREADS:-16}"
WARMUP="${WARMUP:-30}"
DURATION="${DURATION:-120}"
MAX_TRIES="${MAX_TRIES:-50}"
SKIP_INIT="${SKIP_INIT:-false}"
MAX_WAIT="${MAX_WAIT:-900}"

BENCH_NS="yugabyte"
YB_HOST="yb-tservers.yugabyte.svc.cluster.local"
YB_PORT="5433"
YB_USER="yugabyte"
YB_DB="yugabyte"
YB_TS_DNS="yb-tserver-%d.yb-tservers.yugabyte.svc.cluster.local"

# ── helpers ───────────────────────────────────────────────────────────────────
hr()      { echo ""; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }
section() { hr; printf "  %s\n" "$1"; hr; echo ""; }
ts()      { date '+%H:%M:%S'; }

cleanup() {
  echo ""
  echo "==> Cleaning up benchmark jobs..."
  kubectl delete jobs -n "$BENCH_NS" -l bench=yb-official --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete job yb-init -n "$BENCH_NS" --ignore-not-found=true >/dev/null 2>&1 || true
  echo "==> Scaling tservers back to 3 (autoscaler will reclaim nodes in ~5 min)..."
  helm upgrade yugabyte yugabytedb/yugabyte \
    --namespace "$BENCH_NS" \
    --reuse-values \
    --set replicas.tserver=3 \
    --wait=false 2>/dev/null || true
}
trap cleanup EXIT

# ── init schema (single job against headless service) ─────────────────────────
run_init() {
  kubectl delete job yb-init -n "$BENCH_NS" --ignore-not-found=true >/dev/null 2>&1 || true

  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: yb-init
  namespace: ${BENCH_NS}
  labels:
    bench: yb-official
spec:
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: ysql-bench
          image: ${YB_IMAGE}
          command:
            - ${YSQL_BENCH}
          args:
            - -h
            - ${YB_HOST}
            - -p
            - "${YB_PORT}"
            - -U
            - ${YB_USER}
            - -i
            - -s
            - "${SCALE}"
            - --no-vacuum
            - ${YB_DB}
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
EOF

  echo "    Waiting for yb-init pod..."
  for i in $(seq 1 60); do
    PHASE=$(kubectl get pods -n "$BENCH_NS" -l job-name=yb-init \
      -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Pending")
    [[ "$PHASE" == "Running" || "$PHASE" == "Succeeded" ]] && break
    sleep 5
  done

  kubectl logs -n "$BENCH_NS" -l job-name=yb-init -f --tail=100 2>/dev/null || true
  kubectl wait --for=condition=Complete job/yb-init -n "$BENCH_NS" --timeout=1800s >/dev/null 2>&1 || \
    kubectl wait --for=condition=Failed  job/yb-init -n "$BENCH_NS" --timeout=10s  >/dev/null 2>&1 || true
}

# ── distributed benchmark: one job per tserver ───────────────────────────────
# Returns total TPS to stdout; all display to stderr
run_distributed() {
  local LABEL="$1"
  local TS_COUNT="$2"

  local CPT=$(( CLIENTS / TS_COUNT ))
  local TPT=$(( THREADS / TS_COUNT ))
  [[ $CPT -lt 1 ]] && CPT=1
  [[ $TPT -lt 1 ]] && TPT=1

  echo "  Distributing ${CLIENTS} clients across ${TS_COUNT} tservers (${CPT} each)" >&2
  echo "" >&2

  for i in $(seq 0 $(( TS_COUNT - 1 ))); do
    local JOB_NAME="${LABEL}-ts${i}"
    local TS_HOST
    TS_HOST=$(printf "$YB_TS_DNS" "$i")

    kubectl delete job "$JOB_NAME" -n "$BENCH_NS" --ignore-not-found=true >/dev/null 2>&1 || true

    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${BENCH_NS}
  labels:
    bench: yb-official
spec:
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: ysql-bench
          image: ${YB_IMAGE}
          command:
            - ${YSQL_BENCH}
          args:
            - -h
            - ${TS_HOST}
            - -p
            - "${YB_PORT}"
            - -U
            - ${YB_USER}
            - -c
            - "${CPT}"
            - -j
            - "${TPT}"
            - -T
            - "${DURATION}"
            - --no-vacuum
            - --max-tries=${MAX_TRIES}
            - --protocol=prepared
            - -r
            - ${YB_DB}
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
EOF

    echo "    Launched ysql_bench -> yb-tserver-${i}" >&2
  done

  echo "" >&2
  echo "  All ${TS_COUNT} jobs running for ${DURATION}s..." >&2
  echo "" >&2

  local TOTAL_TPS=0
  local TOTAL_TX=0
  local TOTAL_RETRIES=0

  for i in $(seq 0 $(( TS_COUNT - 1 ))); do
    local JOB_NAME="${LABEL}-ts${i}"

    kubectl wait --for=condition=Complete job/"$JOB_NAME" -n "$BENCH_NS" \
      --timeout=$(( DURATION + 120 ))s >/dev/null 2>&1 || \
    kubectl wait --for=condition=Failed   job/"$JOB_NAME" -n "$BENCH_NS" \
      --timeout=10s >/dev/null 2>&1 || true

    local POD
    POD=$(kubectl get pods -n "$BENCH_NS" -l "job-name=${JOB_NAME}" \
      -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || echo "")

    if [[ -n "$POD" ]]; then
      local LOGS
      LOGS=$(kubectl logs -n "$BENCH_NS" "$POD" 2>/dev/null || echo "")

      local TPS_VAL TX_VAL RETRY_VAL
      TPS_VAL=$(echo "$LOGS"   | grep -E "^\s*tps\s*="              | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "0")
      TX_VAL=$(echo "$LOGS"    | grep "transactions actually processed" | grep -oE '[0-9]+'      | tail -1 || echo "0")
      RETRY_VAL=$(echo "$LOGS" | grep "transactions retried"            | grep -oE '[0-9]+'      | head -1 || echo "0")

      printf "    tserver-%-2d | TPS: %8s | tx: %6s | retried: %s\n" \
        "$i" "$TPS_VAL" "$TX_VAL" "$RETRY_VAL" >&2

      TOTAL_TPS=$(python3 -c "print(${TOTAL_TPS} + ${TPS_VAL:-0})")
      TOTAL_TX=$(( TOTAL_TX + ${TX_VAL:-0} ))
      TOTAL_RETRIES=$(( TOTAL_RETRIES + ${RETRY_VAL:-0} ))
    else
      printf "    tserver-%-2d | (no result)\n" "$i" >&2
    fi
  done

  local TOTAL_TPS_R TOTAL_QPS
  TOTAL_TPS_R=$(python3 -c "print(round(${TOTAL_TPS}, 1))")
  TOTAL_QPS=$(python3 -c "print(round(${TOTAL_TPS} * 5))")

  echo "" >&2
  echo "  +------------------------------------------+" >&2
  printf "  |  Total TPS  : %-26s|\n" "${TOTAL_TPS_R}" >&2
  printf "  |  Total QPS  : %-26s|\n" "${TOTAL_QPS}  (TPS x 5 stmts/tx)" >&2
  printf "  |  Total TX   : %-26s|\n" "${TOTAL_TX} in ${DURATION}s" >&2
  printf "  |  Retries    : %-26s|\n" "${TOTAL_RETRIES}" >&2
  echo "  +------------------------------------------+" >&2

  for i in $(seq 0 $(( TS_COUNT - 1 ))); do
    kubectl delete job "${LABEL}-ts${i}" -n "$BENCH_NS" --ignore-not-found=true >/dev/null 2>&1 || true
  done

  echo "$TOTAL_TPS"
}

# ── Phase 1: Cluster state ────────────────────────────────────────────────────
section "Phase 1 — Cluster state ($(ts))"
kubectl get nodes -o wide
echo ""
kubectl get pods -n "$BENCH_NS" -o wide
echo ""
WORKER_COUNT_BEFORE=$(kubectl get nodes \
  --selector='!node-role.kubernetes.io/control-plane' --no-headers | wc -l | tr -d ' ')
echo "  Workers: ${WORKER_COUNT_BEFORE} | Image: ${YB_IMAGE}"

# ── Phase 2: Init schema ──────────────────────────────────────────────────────
section "Phase 2 — Init schema (scale=${SCALE} → $((SCALE * 100))k rows)"

if [[ "$SKIP_INIT" == "true" ]]; then
  echo "  Skipping init (SKIP_INIT=true) — using existing data."
else
  run_init
  echo "  Schema ready. Waiting 30s for tablet rebalancing..."
  sleep 30
fi

# ── Phase 3: Baseline TPS @ 3 tservers ───────────────────────────────────────
BASELINE_CLIENTS=$(( CLIENTS / 4 ))
ORIG_CLIENTS=$CLIENTS
CLIENTS=$BASELINE_CLIENTS

section "Phase 3 — Baseline TPS @ 3 tservers ($(ts))"
echo "  clients=${CLIENTS}  threads=${THREADS}  duration=${DURATION}s  max_tries=${MAX_TRIES}"
echo ""

TPS_BASELINE=$(run_distributed "yb-baseline" 3)
CLIENTS=$ORIG_CLIENTS
echo ""
echo "  Baseline TPS: ${TPS_BASELINE}"

# ── Phase 4: Scale tservers 3→10 ─────────────────────────────────────────────
section "Phase 4 — Scaling tservers 3 -> 10 ($(ts))"
echo "  Anti-affinity forces pending pods -> autoscaler provisions new CAX11 nodes."
echo ""

helm upgrade yugabyte yugabytedb/yugabyte \
  --namespace "$BENCH_NS" \
  --reuse-values \
  --set replicas.tserver=10 \
  --timeout 5m \
  --wait=false

echo ""
echo "==> Watching pods + nodes (max ${MAX_WAIT}s)..."
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

  printf "  [%3ds] nodes: %d (workers: %d) | tservers ready: %s/10  pending: %s\n" \
    "$ELAPSED" "$NODES" "$WORKERS" "$READY" "$PENDING"

  [[ "$READY" -ge 10 ]] && echo "" && echo "  All 10 tservers Running." && break
  sleep 15
done

# ── Phase 5: Cluster state at full scale ─────────────────────────────────────
section "Phase 5 — Cluster state at full scale ($(ts))"
kubectl get nodes -o wide
echo ""
kubectl get pods -n "$BENCH_NS" -l app=yb-tserver -o wide
echo ""
WORKER_COUNT_AFTER=$(kubectl get nodes \
  --selector='!node-role.kubernetes.io/control-plane' --no-headers | wc -l | tr -d ' ')
echo "  Workers: ${WORKER_COUNT_BEFORE} -> ${WORKER_COUNT_AFTER}"

# ── Phase 6: Full-scale TPS @ 10 tservers ────────────────────────────────────
section "Phase 6 — Full-scale TPS @ 10 tservers ($(ts))"
echo "  clients=${CLIENTS}  threads=${THREADS}  duration=${DURATION}s  max_tries=${MAX_TRIES}"
echo ""

TPS_SCALED=$(run_distributed "yb-scaled" 10)

# ── Phase 7: Results ──────────────────────────────────────────────────────────
section "Results ($(ts))"

BASELINE_R=$(python3 -c "print(round(${TPS_BASELINE}, 1))")
SCALED_R=$(python3 -c "print(round(${TPS_SCALED}, 1))")
BASELINE_QPS=$(python3 -c "print(round(${TPS_BASELINE} * 5))")
SCALED_QPS=$(python3 -c "print(round(${TPS_SCALED} * 5))")
SPEEDUP=$(python3 -c "b=${TPS_BASELINE}; s=${TPS_SCALED}; print(round(s/b, 2) if b > 0 else 'N/A')")

printf "  %-28s %-20s %s\n" ""                         "3 tservers"    "10 tservers"
printf "  %-28s %-20s %s\n" "------------------------" "--------------" "--------------"
printf "  %-28s %-20s %s\n" "Total TPS:"               "${BASELINE_R}" "${SCALED_R}"
printf "  %-28s %-20s %s\n" "Total QPS (x5 stmts/tx):" "${BASELINE_QPS}" "${SCALED_QPS}"
printf "  %-28s %-20s %s\n" "Worker nodes:"            "${WORKER_COUNT_BEFORE}" "${WORKER_COUNT_AFTER}"
echo ""
printf "  Speedup: ${SPEEDUP}x  (3 -> 10 tservers)\n"
echo ""
echo "  Autoscaler log (last 10 lines):"
kubectl logs -n kube-system deployment/cluster-autoscaler --tail=10 2>/dev/null || true
