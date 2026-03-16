# InfraLab

InfraLab is a hands-on infrastructure repository for testing, documenting, and publishing real cloud projects.

It is not tied to a single tool or provider. The repo includes labs and working examples across Infrastructure as Code tools such as Terraform, OpenTofu, and Pulumi, with the current main focus on Pulumi and Hetzner Cloud.

## What This Repo Is For

- Build and test real infrastructure patterns
- Keep working code that backs published tutorials
- Compare IaC approaches across tools when useful
- Document practical, cost-focused cloud setups

## Project Index

### Hetzner Cloud

#### 1) Hetzner Private LB + NAT (OpenTofu)
- Path: `hetzner-private-lb-nat-tofu/`
- Focus: private application servers, NAT egress, public load balancer, firewall segmentation
- Best for: production-style private networking on Hetzner Cloud
- Entry docs: `hetzner-private-lb-nat-tofu/README.md`

#### 2) Getting Started with Pulumi on Hetzner Cloud
- Path: `hetzner-pulumi-intro/`
- Focus: first Pulumi + TypeScript deployment on Hetzner Cloud
- Best for: beginners starting with Pulumi on Hetzner
- Entry docs: `hetzner-pulumi-intro/README.md`

#### 3) Private App Server Behind Load Balancer (Pulumi)
- Path: `hetzner-private-lb-pulumi/`
- Focus: public load balancer, private app server, private networking, and firewall rules
- Best for: a clean Pulumi follow-up after the basic Hetzner intro
- Entry docs: `hetzner-private-lb-pulumi/README.md`

#### 4) Queue Buffer on Hetzner Cloud (Pulumi)
- Path: `queue-buffer-hetzner-pulumi/`
- Focus: RabbitMQ + worker + PostgreSQL pattern for absorbing traffic spikes
- Best for: async processing and backend protection patterns
- Entry docs: `queue-buffer-hetzner-pulumi/README.md`

#### 5) YugabyteDB on Hetzner Cloud (Pulumi)
- Path: `yugabyte-hetzner-pulumi/`
- Focus: distributed YugabyteDB cluster with private networking and scaling
- Best for: database infrastructure and benchmark-oriented labs
- Entry docs: `yugabyte-hetzner-pulumi/README.md`

#### 6) YugabyteDB on K3s + Hetzner Cloud (Pulumi)
- Path: `yugabyte-hetzner-k8s/`
- Focus: K3s, Hetzner Cloud, autoscaling, CSI/CCM, and YugabyteDB on Kubernetes
- Best for: advanced platform and database experiments
- Entry docs: `yugabyte-hetzner-k8s/README.md`

### AWS

#### 7) AWS VPC Lab
- Path: `aws-vpc-lab/`
- Focus: simple AWS VPC test configuration
- Best for: basic AWS network lab work
- Entry docs: `aws-vpc-lab/README.md`

## Tooling Overview

This repo currently includes projects built with:

- Pulumi
- OpenTofu
- Terraform

Current direction:
- Main publishing and experimentation focus is Hetzner Cloud
- Main IaC focus is Pulumi for new work
- OpenTofu and Terraform remain part of the lab for comparison and existing projects

## How To Use This Repo

- Start from this index, then open the project folder you want
- Run commands from inside each project directory
- Read the local `README.md` of each project for setup and usage
- Treat tutorial repos and tutorial articles as complementary:
  the repo contains the tested code, while the tutorial explains the step-by-step guide

## Repo Conventions

- Keep each infrastructure project in its own folder
- Do not commit secrets, local state, or private variable files
- Keep project-specific documentation close to the code
- Prefer practical examples that can be tested on real cloud infrastructure

## Notes

- Hetzner Cloud is the main practical platform used here because it is cost-effective and well suited for repeated lab testing
- This repository started earlier with AWS-focused work and is now evolving into a broader InfraLab for multi-cloud and multi-tool experimentation
