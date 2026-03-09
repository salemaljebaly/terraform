# Queue Buffer on Hetzner Cloud (Pulumi + TypeScript)

A production-ready template for absorbing traffic spikes before they hit your database.

Provisions two servers on Hetzner Cloud:
- **Queue server** — RabbitMQ + Worker (Node.js), public IP
- **DB server** — PostgreSQL 17, private network only

## The Problem This Solves

```
Without queue:
  App → 1,000 requests/sec → DB can handle 100/sec → DB crashes

With queue buffer:
  App → 1,000 requests/sec → RabbitMQ (absorbs instantly)
                                   │ worker drains at 100/sec
                                   ▼
                              PostgreSQL (never overwhelmed)
  App response: "Request received" — returned immediately
```

## Architecture

```
Internet
    │
    ▼
Queue Server (public IP)
  ├── RabbitMQ :5672   ← your app publishes here
  ├── RabbitMQ UI :15672
  └── Worker (Node.js) ← reads queue, writes to DB

Private Network (10.10.1.0/24)
    │
    ▼
DB Server (no public IP)
  └── PostgreSQL :5432
```

## Quick Start

```bash
cd queue-buffer-hetzner-pulumi
npm install
cp .env.example .env
# Edit .env — set HCLOUD_TOKEN
set -a && source .env && set +a

pulumi stack init dev
pulumi config set sshKeyName your-ssh-key-name
pulumi config set sshAllowedCidrs '["YOUR_IP/32"]'
pulumi config set --secret hcloudToken $HCLOUD_TOKEN

pulumi up
```

## Stack Outputs

```bash
pulumi stack output queuePublicIp       # Queue server IP
pulumi stack output rabbitmqManagement  # RabbitMQ UI URL
pulumi stack output rabbitmqAmqpUrl     # AMQP connection URL
pulumi stack output postgresPrivateUrl  # PostgreSQL URL (private)
pulumi stack output sshToQueue          # SSH to queue server
pulumi stack output sshToDb             # SSH to DB via jump host
```

## Benchmark

```bash
export QUEUE_IP=$(pulumi stack output queuePublicIp)
export RABBIT_PASS=$(pulumi stack output --show-secrets rabbitmqAmqpUrl | grep -oP '(?<=admin:)[^@]+')

RATE=1000 DURATION=30 ./scripts/benchmark.sh
```

Shows: direct DB limit vs queue absorbing 1,000 msg/sec while DB receives at controlled rate.

## Use Your Own Application

**Only two things to change:**

1. Edit `cloud-init/db-server.yaml` — add your migration SQL in `/opt/db/init/`
2. Edit `cloud-init/queue-server.yaml` — replace the `processMessage()` function in `worker.js`

The `processMessage()` function receives each message and writes to the DB. Example for an order system:

```javascript
async function processMessage(msg) {
  const order = JSON.parse(msg.content.toString());
  await db.query(
    `INSERT INTO orders (customer_id, total, items) VALUES ($1, $2, $3)`,
    [order.customerId, order.total, JSON.stringify(order.items)]
  );
  return true;
}
```

Your app publishes to RabbitMQ:

```javascript
// Node.js example
channel.sendToQueue('events',
  Buffer.from(JSON.stringify({ customerId: 123, total: 99.99, items: [...] })),
  { persistent: true }
);
// Returns instantly — customer sees "Order received"
```

## Tuning

| Config | Default | Description |
|--------|---------|-------------|
| `workerConcurrency` | 10 | Max parallel DB writes (controls drain rate) |
| `dbServerType` | cx22 | DB server spec |
| `queueServerType` | cx22 | Queue server spec |

Higher `workerConcurrency` = faster drain but more DB load. Set it to your DB's comfortable write rate.

## Destroy

```bash
pulumi destroy
```

## Cost

~€8/month (2× cx22 servers on Hetzner).
