# YugabyteDB on K3s + Hetzner (Pulumi + TypeScript)

Production-ready YugabyteDB cluster on Hetzner Cloud using K3s and the official YugabyteDB Helm chart, with full autoscaling and distributed benchmark suite.

## Architecture

```
Pulumi (Phase 1 — infrastructure)
  ├── K3s master   1x cax21  ARM 4vCPU/8GB  — control plane only (tainted)
  └── K3s workers  Nx cax11  ARM 2vCPU/4GB  — YugabyteDB workloads

K8s components (Phase 2 — install-k8s.sh)
  ├── Hetzner CCM         — cloud resources (load balancers, node lifecycle)
  ├── Hetzner CSI         — persistent volumes (hcloud-volumes StorageClass)
  ├── Cluster Autoscaler  — auto-provisions new workers when pods are pending
  └── YugabyteDB Helm     — 3 masters + 3 tservers, RF=3, hcloud-volumes storage

Scaling
  ├── Node level:  Cluster Autoscaler scales workers 3 → 10 automatically
  └── DB level:    YugabyteDB detects new nodes, rebalances tablets automatically
```

**Cost (defaults):** 1x cax21 (~€5.49/mo) + 3x cax11 (~€3.79/mo each) ≈ **€17/mo**

---

## Prerequisites

- Pulumi CLI
- Node.js 20+ and pnpm
- `kubectl` and `helm`
- Hetzner Cloud API token

---

## 1) Setup

```bash
cd yugabyte-hetzner-k8s
pnpm install
cp .env.example .env
# Edit .env — set HCLOUD_TOKEN and PULUMI_CONFIG_PASSPHRASE
set -a && source .env && set +a
```

## 2) Configure Stack

```bash
pulumi stack init dev
```

Set required config (replace `YOUR_IP` with `curl -s ifconfig.me`):

```bash
pulumi config set sshPublicKeyPath ~/.ssh/id_rsa.pub
pulumi config set sshAllowedCidr $(curl -s ifconfig.me)/32
pulumi config set k8sApiAllowedCidr $(curl -s ifconfig.me)/32
```

Optional (defaults defined in `Pulumi.yaml`):

```bash
pulumi config set clusterName my-yb-cluster
pulumi config set workerCount 3
pulumi config set workerMinCount 3
pulumi config set workerMaxCount 10
pulumi config set masterServerType cax21
pulumi config set workerServerType cax11
pulumi config set k3sVersion v1.34.1+k3s1
```

## 3) Deploy Infrastructure (Phase 1)

```bash
pnpm run up
```

Creates: private network, firewalls, master node, worker nodes.
Wait ~3-5 min for K3s to finish bootstrapping.

Stack outputs:

```bash
pulumi stack output masterIp          # master public IP
pulumi stack output sshToMaster       # SSH command
pulumi stack output kubeconfigCmd     # command to download kubeconfig
pulumi stack output autoscalerNodeSpec
```

## 4) Install K8s Components (Phase 2)

```bash
chmod +x scripts/install-k8s.sh
./scripts/install-k8s.sh
```

This script:
1. Downloads kubeconfig from master
2. Creates Hetzner `hcloud` secret (CCM + CSI + autoscaler)
3. Installs Hetzner CCM
4. Installs Hetzner CSI driver
5. Creates `autoscaler-cloud-init` secret (worker join script for new nodes)
6. Deploys Cluster Autoscaler
7. Deploys YugabyteDB via Helm

## 5) Validate

```bash
export KUBECONFIG=$(pwd)/kubeconfig.yaml

# All nodes ready
kubectl get nodes -o wide

# YugabyteDB pods running
kubectl get pods -n yugabyte -o wide

# Cluster health
kubectl exec -n yugabyte -it yb-master-0 -- \
  /home/yugabyte/bin/yugabyted status --base_dir=/home/yugabyte/var

# YSQL connection test
kubectl exec -n yugabyte -it yb-tserver-0 -- \
  /home/yugabyte/bin/ysqlsh -h localhost -p 5433 -U yugabyte -c "SELECT now();"
```

---

## 6) Autoscaling

### How it works

```
Pod pending (no resources on existing workers)
         ↓
Cluster Autoscaler detects pending pod
         ↓
Creates new Hetzner CAX11 server with worker join cloud-init
         ↓
Node joins K3s cluster (~90s)
         ↓
Pod schedules on new node

Scale down:
Node underutilized for 5 minutes → autoscaler drains and deletes it
```

### Scale workers manually

```bash
pulumi config set workerCount 5
pnpm run up
```

### Adjust autoscaler limits

```bash
pulumi config set workerMinCount 3
pulumi config set workerMaxCount 15
# Re-run install-k8s.sh to update the autoscaler deployment
./scripts/install-k8s.sh
```

---

## 7) Benchmarks

Three benchmark scripts are provided to measure TPS/QPS and find the cluster bottleneck.

### benchmark.sh — pgbench TPC-B (standard comparison)

```bash
export KUBECONFIG=$(pwd)/kubeconfig.yaml
./scripts/benchmark.sh

# Skip data init if tables already exist
SKIP_INIT=true ./scripts/benchmark.sh

# Tuning
SCALE=128 CLIENTS=128 THREADS=32 DURATION=120 ./scripts/benchmark.sh
```

**What it does:**
- Runs standard TPC-B workload (pgbench) distributed across all tservers
- Scales tservers 3 → 10 via helm upgrade (triggers autoscaler)
- Reports TPS, QPS, latency per tserver before and after scale

**Results on 10 × CAX11:**

| | 3 tservers | 10 tservers |
|---|---|---|
| Total TPS | ~210 | ~547 |
| Total QPS | ~1,052 | ~2,737 |
| Scale-up time | — | ~150s |

> Note: TPC-B has hot-row contention (pgbench_branches). Lower TPS than realistic workloads.

---

### benchmark-yb.sh — Official ysql_bench (YugabyteDB native)

```bash
export KUBECONFIG=$(pwd)/kubeconfig.yaml
./scripts/benchmark-yb.sh

# Skip init if data exists
SKIP_INIT=true ./scripts/benchmark-yb.sh

# Tuning
SCALE=50 CLIENTS=64 THREADS=16 DURATION=120 MAX_TRIES=50 ./scripts/benchmark-yb.sh
```

**What it does:**
- Uses `ysql_bench` from the official `yugabytedb/yugabyte` image (ARM64 native)
- Auto-detects cluster image version
- `--max-tries=50` retries serialization conflicts automatically
- `--protocol=prepared` for lower per-query overhead
- Distributed: one job per tserver, direct pod DNS

**Results on 10 × CAX11:**

| | 3 tservers | 10 tservers | Speedup |
|---|---|---|---|
| Total TPS | 210.5 | 547.4 | 2.6× |
| Total QPS | 1,052 | 2,737 | 2.6× |
| Init time | — | ~680s (scale=50) | — |

---

### benchmark-k6.sh — Realistic load test (bottleneck finder)

```bash
export KUBECONFIG=$(pwd)/kubeconfig.yaml
./scripts/benchmark-k6.sh

# Tuning
STEP_DURATION=60 ./scripts/benchmark-k6.sh
```

**What it does:**
- Simulates real app traffic: unique UUID inserts + reads (no hot rows)
- Progressive load: 50 → 100 → 200 → 400 concurrent connections
- Stops automatically when TPS plateau is detected (bottleneck found)
- Tests both pure inserts (max write TPS) and mixed 70/30 workload
- Uses `python:3.11-slim` with `asyncpg` (ARM64 native, no custom image needed)

**Results on 10 × CAX11:**

| | 3 tservers | 10 tservers | Speedup |
|---|---|---|---|
| Peak insert ops/sec | 2,440 | 2,560 | 1.05× |
| Peak mixed ops/sec | 2,394 | 2,489 | 1.04× |
| Bottleneck VUs | 50 | 50 | — |
| Insert p95 latency | 32ms | 30ms | — |

> Note: ~2,500 ops/sec is the single load-generator pod ceiling. With distributed load (one pod per tserver), expected throughput is 10,000–15,000 ops/sec on this hardware.

---

### k6-script.js — Run from Mac (optional)

```bash
# Requires k6 with xk6-sql-driver-postgres installed locally
k6 run scripts/k6-script.js \
  -e DB_HOST=<worker-ip> \
  -e DB_PORT=<nodeport> \
  -e WORKLOAD=insert \
  --vus 100 --duration 120s
```

Workload modes: `insert` | `read` | `mixed`

---

## 8) Connect a Backend App

```bash
# Get NodePort
kubectl get svc -n yugabyte

# From inside the cluster (recommended — use smart driver for load distribution)
postgresql://yugabyte@yb-tservers.yugabyte.svc.cluster.local:5433/yugabyte

# From outside via worker NodePort
postgresql://yugabyte@<worker-public-ip>:<node-port>/yugabyte
```

**For production:** use the [YugabyteDB smart driver](https://docs.yugabyte.com/preview/drivers-orms/) for your language. It distributes connections across all tservers automatically.

---

## 9) Destroy

**Important:** Stop the autoscaler first — it creates servers outside Pulumi state.

```bash
export KUBECONFIG=$(pwd)/kubeconfig.yaml
kubectl scale deployment/cluster-autoscaler -n kube-system --replicas=0

# Destroy infra
pnpm run destroy

# Delete any autoscaler-created nodes that Pulumi doesn't track
hcloud server list -l "hcloud/node-group=$(pulumi stack output autoscalerNodeGroup)" \
  -o columns=id -o noheader | xargs -r -n1 hcloud server delete
```

---

## Notes

- Master node is tainted `CriticalAddonsOnly=true:NoSchedule` — YugabyteDB pods never run on it
- `hcloud-volumes` StorageClass uses `reclaimPolicy: Retain` — PVs survive pod deletion
- Storage `count: 1` per pod — one volume per tserver/master (halves Hetzner volume costs)
- Registry mirror for `registry.k8s.io` handles Hetzner CDN blocking issues
- K3s token is generated once by Pulumi and stored encrypted in stack state
- Cluster Autoscaler v1.32.0 — upgraded from v1.31.0 to fix retired `cx11` server type bug
