# Hetzner Private App Stack (OpenTofu)

Production-style OpenTofu project for Hetzner Cloud with:
- Public load balancer
- Private application servers (no public IPs)
- NAT gateway for outbound internet from private subnet
- Network-level segmentation and firewall rules

## Architecture

Internet -> Public Load Balancer -> Private App Servers  
Private App Servers -> NAT (egress) -> Internet

## What This Project Creates

- 1 private Hetzner network (`10.42.0.0/16` by default)
- 2 subnets in that network:
  - Public subnet
  - Private subnet
- 2 private app servers
- 1 public load balancer with health checks
- 1 NAT gateway VM + route for private subnet egress
- Firewalls for app and NAT layers

## Project Files

- `providers.tf`: Provider and Terraform/OpenTofu requirements
- `variables.tf`: Input variables and defaults
- `main.tf`: Shared labels/local values
- `network.tf`: Network and subnet resources
- `nat.tf`: NAT gateway, firewall, private subnet egress route
- `servers.tf`: Private app servers + cloud-init bootstrap
- `load_balancer.tf`: LB, services, and targets
- `firewall.tf`: App server firewall rules
- `outputs.tf`: Public/private infra outputs
- `terraform.tfvars.example`: Example variable file
- `script/`: cloud-init templates

## Quick Start

1. Create vars file:

```bash
cp terraform.tfvars.example terraform.tfvars
```

2. Edit `terraform.tfvars` with your values:
- `hcloud_token`
- `ssh_key_name`
- `ssh_allowed_cidrs`

3. Deploy:

```bash
tofu init
tofu fmt -recursive
tofu validate
tofu plan
tofu apply
```

4. Test:

```bash
LB_IP=$(tofu output -raw load_balancer_public_ipv4)
curl -i "http://$LB_IP/"
```

5. Destroy when done:

```bash
tofu destroy
```

## Private Access Pattern

Use NAT as jump host to access private servers:

```bash
ssh -J root@<nat_gateway_public_ipv4> root@10.42.20.11
```

## Notes

- First boot can take a few minutes before LB health is green.
- Private servers are intentionally not directly internet-reachable.
- Outbound internet from private servers is routed through NAT.

## Security and Publishing

Before publishing:
- Do not commit `terraform.tfvars`
- Do not commit `.terraform/`
- Do not commit `terraform.tfstate*`
- Rotate any token ever stored locally in plain text
