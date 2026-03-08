#!/usr/bin/env bash
# benchmark.sh — YugabyteDB autoscale stress test (max TPS mode).
#
# Strategy:
#   1. Baseline TPS: distributed pgbench across 3 tservers (1 job per tserver)
#   2. Scale tservers 3→10 via helm upgrade → autoscaler provisions new nodes
#   3. Full-scale TPS: distributed pgbench across 10 tservers (1 job per tserver)
#   4. Report: total TPS, QPS, latency, per-tserver breakdown
#
# Each pgbench job connects directly to its tserver pod DNS — no routing bottleneck.
# Total clients split evenly across all tservers.
#
# Usage:
#   export KUBECONFIG=$(pwd)/kubeconfig.yaml
#   ./scripts/benchmark.sh
#
# Tuning (env vars):
#   SCALE      pgbench scale factor (default: 128 → branches=128 > clients/tserver, no hot-row)
#   CLIENTS    total pgbench clients split across tservers (default: 128)
#   THREADS    total threads split across tservers (default: 32)
#   DURATION   seconds per benchmark run (default: 120)
#   MAX_TRIES  max retries per transaction (default: 10)
#   MAX_WAIT   seconds to wait for all 10 tservers ready (default: 900)
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-$(pwd)/kubeconfig.yaml}"
export KUBECONFIG

SCALE="${SCALE:-128}"
CLIENTS="${CLIENTS:-128}"
THREADS="${THREADS:-32}"
DURATION="${DURATION:-120}"
MAX_TRIES="${MAX_TRIES:-10}"
MAX_WAIT="${MAX_WAIT:-900}"

BENCH_NS="yugabyte"
YB_PORT="5433"
YB_DB="yugabyte"
YB_USER="yugabyte"
# Pod DNS pattern for direct tserver connection (StatefulSet DNS)
YB_TS_DNS_PATTERN="yb-tserver-%d.yb-tservers.yugabyte.svc.cluster.local"

# ── helpers ───────────────────────────────────────────────────────────────────
hr()      { echo ""; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }
section() { hr; printf "  %s\n" "$1"; hr; echo ""; }
ts()      { date '+%H:%M:%S'; }

cleanup() {
  echo ""
  echo "==> Cleaning up all benchmark jobs..."
  kubectl delete jobs -n "$BENCH_NS" -l bench=yugabyte-stress --ignore-not-found=true 2>/dev/null || true
  kubectl delete job pgbench-init -n "$BENCH_NS" --ignore-not-found=true 2>/dev/null || true
  echo "==> Scaling tservers back to 3 (allows autoscaler to reclaim nodes)..."
  helm upgrade yugabyte yugabytedb/yugabyte \
    --namespace "$BENCH_NS" \
    --reuse-values \
    --set replicas.tserver=3 \
    --wait=false 2>/dev/null || true
  echo "    Autoscaler will delete idle nodes after ~5 min."
}
trap cleanup EXIT

# ── pgbench init (single job against headless service) ────────────────────────
run_init_job() {
  kubectl delete job pgbench-init -n "$BENCH_NS" --ignore-not-found=true 2>/dev/null || true

  cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: pgbench-init
  namespace: ${BENCH_NS}
  labels:
    bench: yugabyte-stress
spec:
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: pgbench
          image: postgres:16
          env:
            - name: PGPASSWORD
              value: ""
          command: ["pgbench"]
          args:
            - -h
            - "yb-tservers.yugabyte.svc.cluster.local"
            - -p
            - "${YB_PORT}"
            - -U
            - "${YB_USER}"
            - -i
            - -s
            - "${SCALE}"
            - "${YB_DB}"
          resources:
            requests:
              cpu: "500m"
              memory: "256Mi"
EOF

  echo "    Waiting for pgbench-init pod..."
  for i in $(seq 1 60); do
    PHASE=$(kubectl get pods -n "$BENCH_NS" -l job-name=pgbench-init \
      -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Pending")
    [[ "$PHASE" == "Running" || "$PHASE" == "Succeeded" ]] && break
    sleep 5
  done

  kubectl logs -n "$BENCH_NS" -l job-name=pgbench-init -f --tail=200 2>/dev/null || true
  kubectl wait --for=condition=Complete job/pgbench-init -n "$BENCH_NS" --timeout=1800s 2>/dev/null || \
    kubectl wait --for=condition=Failed  job/pgbench-init -n "$BENCH_NS" --timeout=10s  2>/dev/null || true
}

# ── distributed benchmark: one job per tserver ───────────────────────────────
# Usage: run_distributed_bench <label> <tserver_count>
# Returns: total TPS printed to stdout (last line)
run_distributed_bench() {
  local LABEL="$1"
  local TS_COUNT="$2"

  local CLIENTS_PER_TS=$(( CLIENTS / TS_COUNT ))
  local THREADS_PER_TS=$(( THREADS / TS_COUNT ))
  [[ $CLIENTS_PER_TS -lt 1 ]] && CLIENTS_PER_TS=1
  [[ $THREADS_PER_TS -lt 1 ]] && THREADS_PER_TS=1

  echo "  Distributing ${CLIENTS} clients across ${TS_COUNT} tservers (${CLIENTS_PER_TS} clients each)"
  echo ""

  # Launch one pgbench job per tserver in parallel
  for i in $(seq 0 $(( TS_COUNT - 1 ))); do
    local JOB_NAME="${LABEL}-ts${i}"
    # shellcheck disable=SC2059
    local TS_HOST
    TS_HOST=$(printf "$YB_TS_DNS_PATTERN" "$i")

    kubectl delete job "$JOB_NAME" -n "$BENCH_NS" --ignore-not-found=true 2>/dev/null || true

    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${BENCH_NS}
  labels:
    bench: yugabyte-stress
spec:
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: pgbench
          image: postgres:16
          env:
            - name: PGPASSWORD
              value: ""
          command: ["pgbench"]
          args:
            - -h
            - "${TS_HOST}"
            - -p
            - "${YB_PORT}"
            - -U
            - "${YB_USER}"
            - -c
            - "${CLIENTS_PER_TS}"
            - -j
            - "${THREADS_PER_TS}"
            - -T
            - "${DURATION}"
            - --no-vacuum
            - --max-tries=${MAX_TRIES}
            - --protocol=prepared
            - -r
            - "${YB_DB}"
          resources:
            requests:
              cpu: "250m"
              memory: "128Mi"
EOF
    echo "    Launched pgbench → yb-tserver-${i}"
  done

  echo ""
  echo "  All ${TS_COUNT} pgbench jobs running in parallel for ${DURATION}s..."
  echo ""

  # Wait for all jobs and collect TPS
  local TOTAL_TPS=0
  local TOTAL_TX=0
  local TOTAL_RETRIES=0

  for i in $(seq 0 $(( TS_COUNT - 1 ))); do
    local JOB_NAME="${LABEL}-ts${i}"

    kubectl wait --for=condition=Complete job/"$JOB_NAME" -n "$BENCH_NS" \
      --timeout=$(( DURATION + 120 ))s 2>/dev/null || \
    kubectl wait --for=condition=Failed   job/"$JOB_NAME" -n "$BENCH_NS" \
      --timeout=10s 2>/dev/null || true

    local POD
    POD=$(kubectl get pods -n "$BENCH_NS" -l "job-name=${JOB_NAME}" \
      --field-selector=status.phase=Succeeded \
      -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || echo "")

    if [[ -n "$POD" ]]; then
      local LOGS
      LOGS=$(kubectl logs -n "$BENCH_NS" "$POD" 2>/dev/null || echo "")

      local TPS_VAL TX_VAL RETRY_VAL
      TPS_VAL=$(echo "$LOGS"   | grep -E "^\s*tps\s*="                      | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "0")
      TX_VAL=$(echo "$LOGS"    | grep "transactions actually processed"       | grep -oE '^[0-9]+'        | head -1 || echo "0")
      RETRY_VAL=$(echo "$LOGS" | grep "transactions retried"                  | grep -oE '^[0-9]+'        | head -1 || echo "0")

      printf "    tserver-%-2d │ TPS: %8s │ tx: %6s │ retried: %s\n" \
        "$i" "$TPS_VAL" "$TX_VAL" "$RETRY_VAL"

      TOTAL_TPS=$(python3 -c "print(${TOTAL_TPS} + ${TPS_VAL:-0})")
      TOTAL_TX=$(( TOTAL_TX + ${TX_VAL:-0} ))
      TOTAL_RETRIES=$(( TOTAL_RETRIES + ${RETRY_VAL:-0} ))
    else
      printf "    tserver-%-2d │ (no result)\n" "$i"
    fi
  done

  local TOTAL_QPS
  TOTAL_QPS=$(python3 -c "print(round(${TOTAL_TPS} * 5))")

  echo ""
  echo "  ┌─────────────────────────────────────────┐"
  printf "  │  Total TPS  : %-26s│\n" "$(python3 -c "print(round(${TOTAL_TPS}, 1))")"
  printf "  │  Total QPS  : %-26s│\n" "${TOTAL_QPS}  (TPS × 5 stmts/tx)"
  printf "  │  Total TX   : %-26s│\n" "${TOTAL_TX} in ${DURATION}s"
  printf "  │  Retries    : %-26s│\n" "${TOTAL_RETRIES}"
  echo "  └─────────────────────────────────────────┘"

  # Cleanup distributed jobs
  for i in $(seq 0 $(( TS_COUNT - 1 ))); do
    kubectl delete job "${LABEL}-ts${i}" -n "$BENCH_NS" --ignore-not-found=true 2>/dev/null || true
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
echo "  Workers: ${WORKER_COUNT_BEFORE}"

# ── Phase 2: Init pgbench schema ──────────────────────────────────────────────
section "Phase 2 — Init pgbench schema (scale=${SCALE} → branches=${SCALE} rows, accounts=$((SCALE * 100))k rows)"

run_init_job
echo "  Schema ready."

# ── Phase 3: Baseline TPS (3 tservers) ───────────────────────────────────────
section "Phase 3 — Baseline TPS @ 3 tservers ($(ts))"
echo "  total_clients=${CLIENTS}  threads=${THREADS}  duration=${DURATION}s  scale=${SCALE}"
echo ""

TPS_BASELINE=$(run_distributed_bench "bench-baseline" 3)
echo ""
echo "  Baseline TPS: ${TPS_BASELINE}"

# ── Phase 4: Scale tservers 3→10 ──────────────────────────────────────────────
section "Phase 4 — Scaling tservers 3 → 10 ($(ts))"
echo "  Anti-affinity forces pending pods → autoscaler provisions new CAX11 nodes."
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
kubectl get pods -n "$BENCH_NS" -o wide
echo ""
WORKER_COUNT_AFTER=$(kubectl get nodes \
  --selector='!node-role.kubernetes.io/control-plane' --no-headers | wc -l | tr -d ' ')
echo "  Workers: ${WORKER_COUNT_BEFORE} → ${WORKER_COUNT_AFTER}"

# ── Phase 6: Full-scale TPS (10 tservers) ────────────────────────────────────
section "Phase 6 — Full-scale TPS @ 10 tservers ($(ts))"
echo "  total_clients=${CLIENTS}  threads=${THREADS}  duration=${DURATION}s  scale=${SCALE}"
echo ""

TPS_SCALED=$(run_distributed_bench "bench-scaled" 10)

# ── Phase 7: Final report ─────────────────────────────────────────────────────
section "Results ($(ts))"

BASELINE_QPS=$(python3 -c "print(round(${TPS_BASELINE} * 5))")
SCALED_QPS=$(python3 -c "print(round(${TPS_SCALED} * 5))")
SPEEDUP=$(python3 -c "print(round(${TPS_SCALED} / max(${TPS_BASELINE}, 0.1), 2))")

printf "  %-28s %-20s %s\n" "" "3 tservers" "10 tservers"
printf "  %-28s %-20s %s\n" "─────────────────────────" "──────────────" "──────────────"
printf "  %-28s %-20s %s\n" "Total TPS:"  "${TPS_BASELINE}"  "${TPS_SCALED}"
printf "  %-28s %-20s %s\n" "Total QPS (×5 stmts/tx):" "${BASELINE_QPS}" "${SCALED_QPS}"
printf "  %-28s %-20s %s\n" "Worker nodes:" "${WORKER_COUNT_BEFORE}" "${WORKER_COUNT_AFTER}"
echo ""
printf "  Speedup: ${SPEEDUP}×  (3 → 10 tservers)\n"
echo ""
echo "  Autoscaler log (last 15 lines):"
kubectl logs -n kube-system deployment/cluster-autoscaler --tail=15 2>/dev/null || true
