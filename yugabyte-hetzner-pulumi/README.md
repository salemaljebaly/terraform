# YugabyteDB on Hetzner (Pulumi + TypeScript)

This project creates a YugabyteDB cluster on Hetzner Cloud using Pulumi:

- Node count is configurable (`nodeCount`, default 3, minimum 3)
- All nodes have public IPv4 + private IP
- All inter-node traffic goes over Hetzner private network
- YugabyteDB installs and forms the cluster automatically via cloud-init
- Horizontal scaling: one command to add or remove nodes, YugabyteDB rebalances automatically

This is a cost-focused environment. Default uses `CAX11` ARM servers (~€3.79/mo each).

## 1) Prerequisites

- Pulumi CLI installed
- Node.js 20+ and pnpm
- Hetzner Cloud API token
- SSH public key file available locally

## 2) Setup

```bash
cd yugabyte-hetzner-pulumi
pnpm install
cp .env.example .env
```

Edit `.env` with real values, then load it:

```bash
set -a && source .env && set +a
```

## 3) Configure Pulumi Stack

```bash
pulumi stack init dev
```

This project uses local Pulumi state (`file://~` backend in `Pulumi.yaml`), so no `pulumi login` is required.

Set required config (replace `YOUR_PUBLIC_IP` with the output of `curl -s ifconfig.me`):

```bash
pulumi config set sshPublicKeyPath ~/.ssh/id_ed25519.pub
pulumi config set sshAllowedCidr YOUR_PUBLIC_IP/32
pulumi config set ysqlAllowedCidr YOUR_PUBLIC_IP/32
pulumi config set observabilityAllowedCidr YOUR_PUBLIC_IP/32
```

If you already have an SSH key registered in Hetzner, use this instead of `sshPublicKeyPath`:

```bash
pulumi config set existingSshKeyName YOUR_EXISTING_HCLOUD_SSH_KEY_NAME
```

Optional config (defaults already defined in `Pulumi.yaml`):

```bash
pulumi config set nodeCount 3          # number of DB nodes, minimum 3
pulumi config set location nbg1
pulumi config set networkZone eu-central
pulumi config set serverType cax11
pulumi config set image ubuntu-24.04
pulumi config set ybDownloadUrl https://software.yugabyte.com/releases/2025.2.0.1/yugabyte-2025.2.0.1-b1-el8-aarch64.tar.gz
```

Optional naming override:

```bash
pulumi config set namePrefix yb-test-dev
```

By default resource names are stack-aware: `<project>-<stack>`.

## 4) Deploy

```bash
pnpm run up
```

After deploy (~2 min infra + ~10 min cloud-init):

```bash
pulumi stack output publicIpv4      # node-1 public IP (SSH entry point)
pulumi stack output publicIps       # all node public IPs
pulumi stack output privateIps      # all node private IPs
pulumi stack output sshToPublicNode
pulumi stack output ysqlConnection
pulumi stack output ysqlSshTunnel
```

## 5) Validate YugabyteDB

SSH to node-1:

```bash
ssh root@$(pulumi stack output publicIpv4)
```

Check status:

```bash
systemctl status yugabyted
sudo -u yugabyte /opt/yugabyte/bin/yugabyted status --base_dir=/home/yugabyte/yb-data
```

Check all cluster nodes:

```bash
sudo -u yugabyte /opt/yugabyte/postgres/bin/ysqlsh \
  -h 10.30.1.11 -p 5433 -U yugabyte -d yugabyte \
  -c "SELECT host, node_type, cloud, region, zone FROM yb_servers();"
```

Expected output for a 3-node cluster:

```
    host    | node_type |  cloud  | region | zone
------------+-----------+---------+--------+------
 10.30.1.11 | primary   | hetzner | nbg1   | az1
 10.30.1.12 | primary   | hetzner | nbg1   | az2
 10.30.1.13 | primary   | hetzner | nbg1   | az3
```

## 6) Horizontal Scaling

Add or remove nodes with a single config change. YugabyteDB detects new nodes automatically and rebalances data with zero downtime.

**Scale up to 6 nodes:**

```bash
pulumi config set nodeCount 6
pnpm run up
```

**Scale back to 3:**

```bash
pulumi config set nodeCount 3
pnpm run up
```

Node IPs, zones, and join config are all generated automatically:

| Node | Private IP | Cloud Location | Role |
|---|---|---|---|
| 1 | 10.30.1.11 | az1 | bootstrap (others join via this) |
| 2 | 10.30.1.12 | az2 | — |
| 3 | 10.30.1.13 | az3 | — |
| 4 | 10.30.1.14 | az1 | — |
| N | 10.30.1.(10+N) | az(N%3+1) | — |

Limits: minimum 3 nodes (enforced), maximum 10 (Hetzner spread placement group limit).

## 7) TPS Benchmark

YugabyteDB ships `ysql_bench` — its own fork of pgbench — bundled at `/opt/yugabyte/postgres/bin/ysql_bench`.
Use this instead of plain `pgbench`. Key differences:

- `--max-tries` retries serialization errors (expected in distributed SQL, not failures)
- `--no-vacuum` skips VACUUM (YugabyteDB does not use PostgreSQL VACUUM)
- `--protocol=prepared` uses prepared statements for accurate throughput numbers

**Single node benchmark** (run on node-1, connects to node-1):

```bash
scp scripts/benchmark-ysql.sh root@$(pulumi stack output publicIpv4):/root/
ssh root@$(pulumi stack output publicIpv4) '/root/benchmark-ysql.sh 10.30.1.11'
```

**Full cluster benchmark** (all nodes in parallel, run from node-1):

```bash
ssh root@$(pulumi stack output publicIpv4) '
  YSQL="/opt/yugabyte/postgres/bin/ysql_bench"
  ARGS="-p 5433 -U yugabyte -c 32 -j 8 -T 120 --no-vacuum --max-tries=10 --protocol=prepared yugabyte"
  $YSQL -h 10.30.1.11 $ARGS > /tmp/b1.out 2>&1 &
  $YSQL -h 10.30.1.12 $ARGS > /tmp/b2.out 2>&1 &
  $YSQL -h 10.30.1.13 $ARGS > /tmp/b3.out 2>&1 &
  wait
  grep "tps =" /tmp/b1.out /tmp/b2.out /tmp/b3.out
'
```

Add the TPS values together for total cluster TPS. Multiply by 7 for total QPS (7 SQL statements per TPC-B transaction).

Tune load:

```bash
ssh root@$(pulumi stack output publicIpv4) \
  'CLIENTS=64 THREADS=16 DURATION=300 SCALE=100 /root/benchmark-ysql.sh 10.30.1.11'
```

### Benchmark tools overview

| Tool | What it tests | How to get it |
|---|---|---|
| `ysql_bench` | TPC-B TPS (mixed read/write) | Already on each node at `/opt/yugabyte/postgres/bin/ysql_bench` |
| sysbench (YB fork) | OLTP workloads (read-only, read-write, etc.) | Build from source: `github.com/yugabyte/sysbench` (no ARM binary available) |
| TPC-C (yb-tpcc) | Complex OLTP (orders, payments, stock) | Needs Java; see `docs.yugabyte.com/stable/benchmark/tpcc/` |

## 8) Connect a Backend App

YugabyteDB is PostgreSQL-compatible on port 5433. Use any PostgreSQL driver.

**From inside Hetzner private network (recommended):**

```
postgresql://yugabyte@10.30.1.11:5433/yugabyte
```

**From outside via node-1 public IP:**

```
postgresql://yugabyte@<publicIpv4>:5433/yugabyte
```

**SSH tunnel for local development:**

```bash
ssh -L 5433:10.30.1.11:5433 root@$(pulumi stack output publicIpv4)
# then connect to localhost:5433
```

## 9) Destroy

```bash
pnpm run destroy
```

## Notes

- YugabyteDB uses Raft consensus — every write is confirmed by a quorum of nodes before committing. This guarantees zero data loss on node failure but costs some write latency vs single-node PostgreSQL.
- Replication Factor is always 3 regardless of node count. Adding nodes increases throughput and storage, not redundancy level.
- For production, move from `CAX11` to larger plans (`CAX21`, `CAX31`) and run benchmark clients from a separate machine for accurate TPS numbers.
- Pulumi state is stored locally (`~/.pulumi/`). Back it up or use a remote backend for production use.
