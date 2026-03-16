# Two App Servers Behind a Load Balancer (Pulumi + TypeScript)

- 1 public load balancer
- 2 app servers with public IPs, locked down by firewall
- HTTP accepted only from the LB private IP
- SSH only from your allowed CIDRs
- LB routes to servers over the private network (`usePrivateIp: true`)

```
Internet → Load Balancer (public IP) → app-1 or app-2 (over private network)
```

## Prerequisites

- [Pulumi CLI](https://www.pulumi.com/docs/install/) installed
- [Node.js](https://nodejs.org/) 18+
- A Hetzner Cloud API token (Project → Security → API Tokens → Generate)

## Setup

```bash
cd hetzner-private-lb-pulumi
npm install
cp .env.example .env   # fill in HCLOUD_TOKEN and PULUMI_CONFIG_PASSPHRASE
```

```bash
set -a && source .env && set +a
pulumi stack init dev
pulumi config set sshPublicKeyPath ~/.ssh/id_rsa.pub
pulumi config set --secret hcloudToken "$HCLOUD_TOKEN"
pulumi config set sshAllowedCidrs "[\"$(curl -s ifconfig.me)/32\"]"
```

```bash
pulumi preview
pulumi up
```

## Verify

```bash
curl "$(pulumi stack output appUrl)"
curl "$(pulumi stack output appHealthUrl)"   # expected: ok
```

Refresh a few times — you will see responses from `app-1` and `app-2` as the LB distributes traffic.

## Outputs

| Output | Description |
|--------|-------------|
| `loadBalancerPublicIpv4` | Public IP of the load balancer |
| `appUrl` | HTTP URL to access the app |
| `appHealthUrl` | Health check endpoint |
| `server1Name` / `server2Name` | Names of the app servers |
| `server1PrivateIp` / `server2PrivateIp` | Private IPs of the app servers |

## Destroy

```bash
pulumi destroy
pulumi stack rm dev
```
