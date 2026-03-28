# YugabyteDB on Hetzner (Pulumi + TypeScript)

This project creates a production-style YugabyteDB cluster on Hetzner Cloud using Pulumi:

- 3-node RF=3 cluster across 3 fault zones (az1/az2/az3)
- DB nodes are **private only** — no public DB ports, no internet access to 5433
- App server sits on the same private network, HTTP port 80 is the only public entry point
- YugabyteDB installs and forms the cluster automatically via cloud-init
- Horizontal scaling: one config change to add or remove nodes, YugabyteDB rebalances automatically

Default server type: `cax21` (4 vCPU / 8 GB ARM) — best price/performance ratio on Hetzner for this workload.

## Architecture

```
Internet
    │
    ▼
App Server  (public IPv4, port 80)
    │
    │  private network 10.30.1.0/24  (~1ms latency)
    ▼
YugabyteDB nodes  (private only)
10.30.1.11 / .12 / .13
port 5433, 7000-9000 — subnet access only
```

## 1) Prerequisites

- Pulumi CLI installed
- Node.js 20+ and pnpm
- Hetzner Cloud API token
- SSH public key file available locally

## 2) Setup

```bash
cd yugabyte-hetzner-pulumi
pnpm install
```

Create a `.env` file:

```bash
HCLOUD_TOKEN=your_hetzner_api_token_here
PULUMI_CONFIG_PASSPHRASE=your_passphrase_here
```

```bash
echo ".env" >> .gitignore
set -a && source .env && set +a
```

## 3) Configure Pulumi Stack

```bash
pulumi stack init dev
pulumi config set sshPublicKeyPath ~/.ssh/id_ed25519.pub
pulumi config set sshAllowedCidr $(curl -s ifconfig.me)/32
```

If you already have an SSH key registered in Hetzner:

```bash
pulumi config set existingSshKeyName YOUR_EXISTING_HCLOUD_SSH_KEY_NAME
```

Optional config (defaults shown):

```bash
pulumi config set nodeCount 3           # minimum 3, maximum 10
pulumi config set serverType cax21      # DB node type (ARM)
pulumi config set appServerType cax21   # App server type
pulumi config set location nbg1
pulumi config set networkZone eu-central
pulumi config set image ubuntu-24.04
pulumi config set ybDownloadUrl https://software.yugabyte.com/releases/2025.2.0.1/yugabyte-2025.2.0.1-b1-el8-aarch64.tar.gz
```

## 4) Deploy

```bash
set -a && source .env && set +a
pulumi preview
pulumi up
```

After deploy (~2 min infra + ~10 min cloud-init):

```bash
pulumi stack output appUrl              # app server public URL
pulumi stack output appHealthUrl        # health endpoint
pulumi stack output sshToApp            # SSH to app server
pulumi stack output sshToPublicNode     # SSH to DB node-1
pulumi stack output ysqlSshTunnel       # SSH tunnel for local YSQL access
```

## 5) Validate

**App layer:**

```bash
curl http://$(pulumi stack output appPublicIp)/health
curl http://$(pulumi stack output appPublicIp)/db/ping
curl -X POST http://$(pulumi stack output appPublicIp)/events \
  -H "Content-Type: application/json" -d '{"payload":"hello"}'
```

**DB cluster (via SSH tunnel):**

```bash
# Open tunnel
ssh -L 5433:10.30.1.11:5433 root@$(pulumi stack output publicIpv4)

# In another terminal
psql postgresql://yugabyte@localhost:5433/yugabyte \
  -c "SELECT host, node_type, zone FROM yb_servers();"
```

Expected output for 3-node cluster:

```
    host    | node_type | zone
------------+-----------+------
 10.30.1.11 | primary   | az1
 10.30.1.12 | primary   | az2
 10.30.1.13 | primary   | az3
```

## 6) Horizontal Scaling

Scale up to 4 nodes:

```bash
pulumi config set nodeCount 4
pulumi up
```

Scale back to 3:

```bash
pulumi config set nodeCount 3
pulumi up
```

Node IPs, zones, and join config are generated automatically:

| Node | Private IP | Cloud Location |
|------|-----------|----------------|
| 1 | 10.30.1.11 | az1 (bootstrap) |
| 2 | 10.30.1.12 | az2 |
| 3 | 10.30.1.13 | az3 |
| N | 10.30.1.(10+N) | az(N%3+1) |

Minimum: 3 nodes (enforced). Maximum: 10 (Hetzner spread placement group limit).

## 7) Benchmark Results

Tested on 3× cax21 (4 vCPU / 8 GB ARM) + 1× cax21 app server, Hetzner nbg1, private network ~1ms.

### pgbench (direct DB connection, scale=100 / 10M rows)

| Test | Clients | TPS |
|------|---------|-----|
| TPC-B read-write | 32 | **624 TPS** |
| Read-only | 32 | **7,055 TPS** |
| Pure INSERT (UUID, no hot rows) | 64 | **6,664 TPS** |

### API layer (Node.js → YugabyteDB over private network)

| Endpoint | Concurrency | RPS |
|----------|-------------|-----|
| POST /events (write) | 100 | **875 RPS** |
| GET /events/count (read) | 100 | **752 RPS** |
| GET /db/ping | 100 | **1,110 RPS** |

### Why TPC-B write TPS is lower than pure INSERT

TPC-B has 100 branch rows shared across all clients — a hot-row lock contention problem by design, not a YugabyteDB limitation. Pure INSERT with UUID primary key distributes writes across all tablets and hits the real RAFT throughput ceiling (~6,600 TPS).

The read-only result (7,055 TPS) exceeds typical x86 results on AWS at this scale — ARM's memory bandwidth advantage shows clearly on read-heavy workloads.

### Run the benchmark yourself

```bash
# Init scale=100 (10M rows) — takes ~15 min
pgbench -h 10.30.1.11 -p 5433 -U yugabyte -i -s 100 yugabyte

# Read-write TPC-B
pgbench -h 10.30.1.11 -p 5433 -U yugabyte -d yugabyte -c 32 -j 8 -T 120

# Read-only
pgbench -h 10.30.1.11 -p 5433 -U yugabyte -d yugabyte -c 32 -j 8 -T 120 -S

# Pure INSERT (no hot rows)
echo "INSERT INTO events (payload) VALUES (md5(random()::text));" > /tmp/insert.sql
pgbench -h 10.30.1.11 -p 5433 -U yugabyte -d yugabyte -c 64 -j 8 -T 60 -f /tmp/insert.sql
```

Or use the pre-built benchmark command from Pulumi outputs:

```bash
pulumi stack output benchmarkCmd
```

## 8) App Server API

The app server runs a Node.js Express API connected to YugabyteDB over the private network.

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Returns `{"status":"ok"}` |
| `/db/ping` | GET | Returns YugabyteDB version string |
| `/events` | POST | Insert event `{"payload":"..."}` |
| `/events/count` | GET | Count all events |

The events table uses UUID primary key for optimal write distribution across YugabyteDB tablets:

```sql
CREATE TABLE events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  payload TEXT NOT NULL
)
```

## 9) Destroy

```bash
set -a && source .env && set +a
pulumi destroy
pulumi stack rm dev
```

## Notes

- YugabyteDB uses RAFT consensus — every write is confirmed by 2/3 nodes before committing. This guarantees zero data loss on node failure but adds ~1ms write latency vs single-node PostgreSQL.
- Replication Factor is always 3 regardless of node count. Adding nodes increases throughput and storage capacity, not the redundancy level.
- Write throughput scales with UUID-keyed workloads (no hot rows). Avoid BIGSERIAL/SERIAL primary keys under high write load — the distributed sequence allocator becomes a bottleneck.
- Pulumi state is stored locally (`~/.pulumi/`). Back it up or switch to a remote backend for production use.
