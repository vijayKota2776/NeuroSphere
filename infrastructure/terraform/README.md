# NeuroSphere — Terraform Infrastructure

## Overview

This directory contains the Infrastructure as Code (IaC) for the NeuroSphere Medical Robotics Platform, built with **Terraform** targeting **AWS**.

## Architecture

```
infrastructure/terraform/
├── main.tf              # Root module — orchestrates all sub-modules
├── variables.tf         # Root variables
├── outputs.tf           # Root outputs
├── providers.tf         # Provider configuration (AWS, Kubernetes, Helm)
├── backend.tf           # State backend configuration
├── Makefile             # Convenience targets
│
├── modules/
│   ├── networking/      # VPC, subnets, NAT, flow logs
│   ├── kubernetes/      # EKS cluster, node groups, OIDC
│   ├── security/        # ECR, WAF, state bucket, audit logs
│   └── monitoring/      # CloudWatch, SNS, dashboards, alarms
│
└── environments/
    ├── dev/             # Development (small, cost-optimized)
    ├── staging/         # Staging (moderate, integration testing)
    └── prod/            # Production (HA, encrypted, private)
```

## Modules

| Module | Purpose | Key Resources |
|--------|---------|---------------|
| **networking** | Network foundation | VPC, 3-tier subnets (public/private/database), NAT Gateway, VPC Flow Logs |
| **kubernetes** | Container orchestration | EKS cluster, managed node groups, KMS encryption, OIDC provider |
| **security** | Security & compliance | ECR repos, WAF, S3 state bucket, DynamoDB lock, audit log bucket |
| **monitoring** | Observability | CloudWatch log groups, metric alarms, SNS alerts, operations dashboard |

## Environment Sizing

| Setting | Dev | Staging | Prod |
|---------|-----|---------|------|
| Instance Types | t3.medium | t3.large | t3.xlarge, t3.2xlarge |
| Min Nodes | 1 | 2 | 3 |
| Max Nodes | 3 | 4 | 10 |
| HA NAT | ❌ | ❌ | ✅ (multi-AZ) |
| Public API | ✅ | ✅ | ❌ (private only) |
| Log Retention | 30 days | 30 days | 90 days |

## Quick Start

```bash
# 1. Initialize dev environment
make init-dev

# 2. Review planned changes
make plan-dev

# 3. Apply infrastructure
make apply-dev

# 4. Get kubeconfig
aws eks update-kubeconfig --region us-east-1 --name neurosphere-dev
```

## Healthcare Compliance

- **HIPAA**: KMS encryption at rest, VPC Flow Logs, private EKS endpoint (prod), audit trails
- **IEC 62443**: Network segmentation (3-tier subnets), security groups, WAF protection
- **Immutable Infrastructure**: ECR tags are immutable, all changes via Terraform

## Prerequisites

- Terraform >= 1.5.0
- AWS CLI configured with appropriate credentials
- S3 bucket and DynamoDB table for state backend (created by security module)
