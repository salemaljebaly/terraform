# Queue Buffer on Hetzner Cloud (Pulumi + TypeScript)

A production-ready template for absorbing traffic spikes before they hit your database.

Provisions two servers on Hetzner Cloud using Pulumi — **from zero to ready in ~30 seconds** (Hetzner Docker CE app image):
- **Queue server** — RabbitMQ 4.2.4 + Worker (Node.js), public IP
- **DB server** — PostgreSQL 18.3 Alpine, public IP (firewall-restricted)

## The Problem This Solves

```
Without queue:
  App → 10,000 req/sec → DB handles ~800/sec → DB crashes

With queue buffer:
  App → 10,000 req/sec → RabbitMQ (absorbs all instantly)
                               │ worker drains at controlled rate
                               ▼
                          PostgreSQL (never overwhelmed)
  App response: "Request received" — returned immediately
```

## Architecture

```
Internet
    │
    ├── App publishes → Queue Server (public IP)
    │                     ├── RabbitMQ :5672    ← app connects here
    │                     ├── RabbitMQ UI :15672
    │                     └── Worker (Node.js)  ← drains queue to DB
    │
    └── SSH/admin    → DB Server (public IP, firewall-restricted)
                          └── PostgreSQL :5432  ← only queue server can write
```

## Benchmark Results

Tested on **cx23 (2 vCPU / 4GB RAM)** — both tests over internet for fair comparison:

| Metric | Result |
|--------|--------|
| PostgreSQL direct inserts (internet) | **~786 inserts/sec** |
| RabbitMQ publish rate (internet) | **~9,800 msg/sec** |
| Worker drain rate (private network) | **~3,000 msg/sec** |
| Queue advantage | **12.5× faster than direct DB** |

```
User sends 10,000 req/sec
        │
        ▼
RabbitMQ accepts all instantly   (~9,800/sec ceiling from internet)
        │
        ▼
Worker drains to DB              (~3,000/sec — improvable via workerConcurrency)
        │
        ▼
PostgreSQL writes safely         (~8,000/sec on private network)
```

**The queue absorbs 12.5× more traffic than PostgreSQL can handle directly from the internet.**

## Quick Start

```bash
cd queue-buffer-hetzner-pulumi
pnpm install
cp .env.example .env
# Edit .env — set HCLOUD_TOKEN
set -a && source .env && set +a

pulumi stack init dev

# Option A — upload your local SSH key automatically (recommended)
pulumi config set sshPublicKeyPath ~/.ssh/id_rsa.pub

# Option B — use an existing key already in Hetzner
# pulumi config set sshKeyName your-existing-key-name

pulumi config set sshAllowedCidrs "[\"$(curl -s ifconfig.me)/32\"]"
pulumi config set --secret hcloudToken $HCLOUD_TOKEN

pulumi up
```

## Stack Outputs

```bash
pulumi stack output queuePublicIp       # Queue server IP
pulumi stack output dbPublicIp          # DB server IP
pulumi stack output rabbitmqManagement  # RabbitMQ UI — http://<ip>:15672
pulumi stack output rabbitmqAmqpUrl     # AMQP connection URL (secret)
pulumi stack output postgresUrl         # PostgreSQL URL (secret)
pulumi stack output sshToQueue          # SSH to queue server
pulumi stack output sshToDb             # SSH to DB server
```

## Benchmark

```bash
export QUEUE_IP=$(pulumi stack output queuePublicIp)
export RABBIT_PASS=$(pulumi stack output --show-secrets rabbitmqAmqpUrl | sed 's/amqp:\/\/admin://;s/@.*//')
export DB_IP=$(pulumi stack output dbPublicIp)
export DB_PASS=$(pulumi stack output --show-secrets postgresUrl | sed 's|postgresql://appuser:||;s|@.*||')

./scripts/benchmark.sh
```

Runs three phases:
1. **DB ceiling** — direct inserts over internet via SSH tunnel
2. **RabbitMQ ceiling** — publish rate from internet
3. **Worker drain** — how fast queue empties to DB

## Use Your Own Application

**Only two things to change:**

**1.** Add your migration SQL in `cloud-init/db-server.yaml` under `/opt/db/init/`

**2.** Replace `processMessage()` in `cloud-init/queue-server.yaml`:

```javascript
async function processMessage(msg) {
  const data = JSON.parse(msg.content.toString());
  // your logic here — insert order, send notification, process event, etc.
  await db.query('INSERT INTO your_table ...', [...]);
  return true; // acknowledge message
}
```

Your app publishes to RabbitMQ:

```javascript
channel.sendToQueue('events',
  Buffer.from(JSON.stringify({ your: 'data' })),
  { persistent: true }
);
// Returns instantly — no waiting for DB
```

## Tuning

| Config | Default | Description |
|--------|---------|-------------|
| `workerConcurrency` | 10 | Parallel DB writes — increase to push more toward DB ceiling |
| `dbServerType` | cx23 | DB server spec |
| `queueServerType` | cx23 | Queue server spec |

Higher `workerConcurrency` → faster drain → more DB load. Start at 10, increase until DB CPU hits ~70%.

## Destroy

```bash
pulumi destroy
```

## Cost

~€8/month (2× cx23 on Hetzner).
