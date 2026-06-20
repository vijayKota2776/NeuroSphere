# NeuroSphere — Security Infrastructure

## Overview

This directory contains all security configurations, policies, and tooling for the NeuroSphere Medical Robotics Platform.

## Architecture

```
security/
├── vault/                          # HashiCorp Vault secrets management
│   ├── config/vault-config.hcl     # Vault server configuration
│   ├── policies/                   # 5 access control policies
│   │   ├── neurosphere-admin.hcl       # Full admin access
│   │   ├── neurosphere-services.hcl    # Shared service read-only
│   │   ├── neurosphere-robot-command.hcl
│   │   ├── neurosphere-patient-monitor.hcl  # PHI-scoped (strictest)
│   │   └── neurosphere-cicd.hcl        # CI/CD pipeline access
│   ├── scripts/init-vault.sh       # 13-step initialization script
│   ├── kubernetes/                 # K8s manifests for Vault deployment
│   └── secrets/seed-secrets.json   # Template secrets (CHANGE_ME values)
│
├── scanning/                       # Security scanning tools
│   ├── trivy.yaml                  # Container vulnerability scanner config
│   ├── .bandit.yml                 # Python SAST scanner config
│   ├── owasp-dc-suppression.xml   # OWASP false positive suppressions
│   └── run-security-scan.sh        # Unified scan runner script
│
├── compliance/                     # Regulatory compliance
│   ├── hipaa-checklist.md          # HIPAA §164.312 control mapping
│   └── security-policy.md         # Organizational security policy
│
└── docker/
    └── docker-bench-config.yml     # CIS Docker Benchmark config
```

## Quick Start

### 1. Initialize Vault
```bash
# Deploy Vault to Kubernetes
kubectl apply -f vault/kubernetes/

# Run initialization (after Vault pod is running)
chmod +x vault/scripts/init-vault.sh
./vault/scripts/init-vault.sh
```

### 2. Run Security Scans
```bash
chmod +x scanning/run-security-scan.sh
./scanning/run-security-scan.sh --service all --severity-threshold HIGH
```

### 3. Access Vault UI
```bash
kubectl port-forward svc/vault 8200:8200 -n neurosphere-vault
# Open http://localhost:8200
```

## Vault Policy Summary

| Policy | Scope | Use Case |
|--------|-------|----------|
| `neurosphere-admin` | Full access | Infrastructure team only |
| `neurosphere-services` | Read-only shared secrets | All microservices |
| `neurosphere-robot-command` | Robot DB, surgical controller keys | Robot command service |
| `neurosphere-patient-monitor` | Patient DB, PHI encryption, HIPAA certs | Patient monitor (strictest) |
| `neurosphere-cicd` | Docker registry, GitHub, SonarQube | Jenkins pipelines |

## Compliance

- **HIPAA**: See [hipaa-checklist.md](compliance/hipaa-checklist.md) for full control mapping
- **Security Policy**: See [security-policy.md](compliance/security-policy.md) for organizational policy
- **IEC 62443**: Network segmentation via K8s network policies + Vault RBAC
- **FDA 21 CFR Part 11**: Audit logging, immutable image tags, approval gates
