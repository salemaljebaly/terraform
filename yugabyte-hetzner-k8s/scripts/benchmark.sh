#!/usr/bin/env bash
# benchmark.sh — YugabyteDB autoscale stress test.
#
# Strategy:
#   1. Baseline TPS with 3 tservers / 3 worker nodes
#   2. Scale tservers 3→10 via helm upgrade (anti-affinity forces 7 new pending pods)
#   3. Autoscaler provisions up to 10 CAX11 worker nodes to schedule them
#   4. Final TPS with 10 tservers / 10 worker nodes
#   5. Report before/after comparison
#
# Usage:
#   export KUBECONFIG=$(pwd)/kubeconfig.yaml
#   ./scripts/benchmark.sh
#
# Tuning (env vars):
#   SCALE      pgbench scale factor; 1 unit ≈ 100k rows (default: 50 ≈ 5M rows)
#   CLIENTS    pgbench client connections (default: 32)
#   THREADS    pgbench threads (default: 8)
#   DURATION   seconds per benchmark run (default: 120)
#   MAX_WAIT   seconds to wait for all 10 tservers ready (default: 900)
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-$(pwd)/kubeconfig.yaml}"
export KUBECONFIG

SCALE="${SCALE:-50}"
CLIENTS="${CLIENTS:-32}"
THREADS="${THREADS:-8}"
DURATION="${DURATION:-120}"
MAX_WAIT="${MAX_WAIT:-900}"

BENCH_NS="yugabyte"
YB_SERVICE="yb-tservers.yugabyte.svc.cluster.local"
YB_PORT="5433"
YB_DB="yugabyte"
YB_USER="yugabyte"

# ── helpers ───────────────────────────────────────────────────────────────────
hr()      { echo ""; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }
section() { hr; printf "  %s\n" "$1"; hr; echo ""; }
ts()      { date '+%H:%M:%S'; }

cleanup() {
  echo ""
  echo "==> Cleaning up benchmark jobs..."
  kubectl delete job pgbench-init pgbench-baseline pgbench-scaled \
    -n "$BENCH_NS" --ignore-not-found=true 2>/dev/null || true
}
trap cleanup EXIT

# Run a pgbench job and stream its logs; print the TPS line at the end.
# Usage: run_pgbench <job-name> <extra-args...>
run_pgbench_job() {
  local JOB_NAME="$1"; shift
  local EXTRA_ARGS=("$@")

  kubectl delete job "$JOB_NAME" -n "$BENCH_NS" --ignore-not-found=true 2>/dev/null || true

  cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${BENCH_NS}
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
            - "${YB_SERVICE}"
            - -p
            - "${YB_PORT}"
            - -U
            - "${YB_USER}"
$(for arg in "${EXTRA_ARGS[@]}"; do printf "            - \"%s\"\n" "$arg"; done)
            - "${YB_DB}"
          resources:
            requests:
              cpu: "500m"
              memory: "256Mi"
EOF

  # Wait for pod to start
  echo "    Waiting for ${JOB_NAME} pod..."
  for i in $(seq 1 60); do
    PHASE=$(kubectl get pods -n "$BENCH_NS" -l job-name="$JOB_NAME" \
      -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Pending")
    [[ "$PHASE" == "Running" || "$PHASE" == "Succeeded" ]] && break
    sleep 5
  done

  kubectl logs -n "$BENCH_NS" -l "job-name=${JOB_NAME}" -f --tail=500 2>/dev/null || true

  # Wait for completion and check exit
  kubectl wait --for=condition=Complete job/"$JOB_NAME" -n "$BENCH_NS" --timeout=600s 2>/dev/null || \
    kubectl wait --for=condition=Failed   job/"$JOB_NAME" -n "$BENCH_NS" --timeout=10s  2>/dev/null || true
}

# Extract TPS from last pgbench logs
get_tps() {
  local JOB_NAME="$1"
  kubectl logs -n "$BENCH_NS" -l "job-name=${JOB_NAME}" 2>/dev/null \
    | grep -E "^tps\s*=" | tail -1 || echo "(not captured)"
}

# ── Phase 1: Baseline state ───────────────────────────────────────────────────
section "Phase 1 — Cluster state ($(ts))"

kubectl get nodes -o wide
echo ""
kubectl get pods -n "$BENCH_NS" -o wide
echo ""
NODE_COUNT_BEFORE=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
WORKER_COUNT_BEFORE=$(kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' --no-headers | wc -l | tr -d ' ')
echo "  Control-plane + workers: $NODE_COUNT_BEFORE  (workers: $WORKER_COUNT_BEFORE)"

# ── Phase 2: Init pgbench schema ──────────────────────────────────────────────
section "Phase 2 — Init pgbench schema (scale=${SCALE}, ~$((SCALE * 100))k rows)"

run_pgbench_job "pgbench-init" "-i" "-s" "${SCALE}"
echo "  Schema ready."

# ── Phase 3: Baseline TPS (3 tservers) ───────────────────────────────────────
section "Phase 3 — Baseline TPS @ 3 tservers ($(ts))"
echo "  clients=${CLIENTS}  threads=${THREADS}  duration=${DURATION}s"
echo ""

run_pgbench_job "pgbench-baseline" \
  "-c" "${CLIENTS}" \
  "-j" "${THREADS}" \
  "-T" "${DURATION}" \
  "--no-vacuum" \
  "-r"

TPS_BASELINE=$(get_tps "pgbench-baseline")
echo ""
echo "  Baseline result: ${TPS_BASELINE}"

# ── Phase 4: Scale tservers 3→10 (triggers autoscaling) ──────────────────────
section "Phase 4 — Scaling tservers 3 → 10 ($(ts))"
echo "  Anti-affinity forces 7 new pending pods → autoscaler provisions 7 CAX11 nodes."
echo ""

helm upgrade yugabyte yugabytedb/yugabyte \
  --namespace "$BENCH_NS" \
  --reuse-values \
  --set replicas.tserver=10 \
  --timeout 5m \
  --wait=false   # don't wait here — we'll watch manually

echo ""
echo "==> Tserver scale submitted. Watching pods + nodes (max ${MAX_WAIT}s)..."
echo ""

START_TS=$SECONDS

while true; do
  ELAPSED=$(( SECONDS - START_TS ))
  if [[ $ELAPSED -gt $MAX_WAIT ]]; then
    echo "  WARN: Timed out waiting for 10 tservers. Continuing anyway."
    break
  fi

  READY_TSERVERS=$(kubectl get pods -n "$BENCH_NS" -l app=yb-tserver \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')

  PENDING_TSERVERS=$(kubectl get pods -n "$BENCH_NS" -l app=yb-tserver \
    --field-selector=status.phase=Pending \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')

  NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  WORKER_COUNT=$(kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' --no-headers 2>/dev/null | wc -l | tr -d ' ')

  printf "  [%3ds] nodes: %d (workers: %d) | tservers ready: %s/10  pending: %s\n" \
    "$ELAPSED" "$NODE_COUNT" "$WORKER_COUNT" "$READY_TSERVERS" "$PENDING_TSERVERS"

  if [[ "$READY_TSERVERS" -ge 10 ]]; then
    echo ""
    echo "  All 10 tservers Running."
    break
  fi

  sleep 15
done

# ── Phase 5: Final cluster state ──────────────────────────────────────────────
section "Phase 5 — Cluster state at full scale ($(ts))"

kubectl get nodes -o wide
echo ""
kubectl get pods -n "$BENCH_NS" -o wide
echo ""
NODE_COUNT_AFTER=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
WORKER_COUNT_AFTER=$(kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' --no-headers | wc -l | tr -d ' ')
echo "  Workers before: $WORKER_COUNT_BEFORE → after: $WORKER_COUNT_AFTER"

# ── Phase 6: Full-scale TPS (10 tservers) ────────────────────────────────────
section "Phase 6 — Full-scale TPS @ 10 tservers ($(ts))"
echo "  clients=${CLIENTS}  threads=${THREADS}  duration=${DURATION}s"
echo ""

run_pgbench_job "pgbench-scaled" \
  "-c" "${CLIENTS}" \
  "-j" "${THREADS}" \
  "-T" "${DURATION}" \
  "--no-vacuum" \
  "-r"

TPS_SCALED=$(get_tps "pgbench-scaled")

# ── Phase 7: Report ───────────────────────────────────────────────────────────
section "Results"
printf "  %-30s %s\n" "Workers before:" "$WORKER_COUNT_BEFORE"
printf "  %-30s %s\n" "Workers after:"  "$WORKER_COUNT_AFTER"
printf "  %-30s %s\n" "Tservers before:" "3"
printf "  %-30s %s\n" "Tservers after:"  "10"
echo ""
printf "  %-30s %s\n" "Baseline TPS (3 tservers):"  "$TPS_BASELINE"
printf "  %-30s %s\n" "Full-scale TPS (10 tservers):" "$TPS_SCALED"
echo ""
echo "  Autoscaler log (last 20 lines):"
kubectl logs -n kube-system deployment/cluster-autoscaler --tail=20 2>/dev/null || true
echo ""
echo "  NOTE: tservers will remain at 10. To reset:"
echo "    helm upgrade yugabyte yugabytedb/yugabyte -n yugabyte --reuse-values --set replicas.tserver=3"
echo "  Autoscaler will then scale down idle nodes after ~5 min."
