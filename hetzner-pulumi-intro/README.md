# Getting Started with Pulumi and TypeScript on Hetzner Cloud

Companion code for the [Hetzner Community Tutorial](https://community.hetzner.com/tutorials/getting-started-pulumi-hetzner-typescript).

## Quick Start

```bash
npm install
pulumi login --local
pulumi stack init dev
pulumi config set --secret hcloudToken YOUR_HETZNER_TOKEN
pulumi preview
pulumi up
```

## Outputs

```bash
pulumi stack output serverIp    # public IP of the server
pulumi stack output serverName  # server name
```

## Destroy

```bash
pulumi destroy
```
