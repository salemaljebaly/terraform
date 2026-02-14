# Terraform Workspace Index

This repository contains infrastructure projects managed with Terraform/OpenTofu.

## Project Index

### 1) Hetzner Private LB + NAT (OpenTofu)
- Path: `hetzner-private-lb-nat-tofu/`
- Purpose: Public load balancer + private app servers + NAT egress + firewall segmentation.
- Entry docs: `hetzner-private-lb-nat-tofu/README.md`

### 2) AWS VPC Lab
- Path: `aws-vpc-lab/`
- Purpose: Simple AWS VPC test configuration.
- Entry docs: `aws-vpc-lab/README.md`

## Recommended Structure Going Forward

For each new infrastructure project, use a dedicated folder:

```text
terraform/
├── README.md
├── project-a/
│   ├── README.md
│   └── *.tf
├── project-b/
│   ├── README.md
│   └── *.tf
└── ...
```

## Usage Guidance

- Always run Terraform/OpenTofu commands from the target project directory.
- Keep per-project variable files local (`terraform.tfvars`) and never commit secrets.
- Keep state files out of git (`*.tfstate`, `.terraform/`) as defined in `.gitignore`.
