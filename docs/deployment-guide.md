# NeuroSphere — Deployment Guide

> Step-by-step instructions for deploying the NeuroSphere platform in local, staging, and production environments

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Local Development](#2-local-development-docker-compose)
3. [AWS Infrastructure Provisioning](#3-aws-infrastructure-provisioning)
4. [Kubernetes Deployment](#4-kubernetes-deployment)
5. [Monitoring Stack Setup](#5-monitoring-stack-setup)
6. [Vault Initialization](#6-vault-initialization)
7. [Jenkins CI/CD Setup](#7-jenkins-cicd-setup)
8. [Post-Deployment Verification](#8-post-deployment-verification)
9. [Live EC2 Deployment](#9-live-ec2-deployment)
10. [Troubleshooting FAQ](#10-troubleshooting-faq)

---

## 1. Prerequisites

### Required Tools

| Tool | Version | Installation | Purpose |
|------|---------|--------------|---------|
| Docker | ≥ 24.0 | [docs.docker.com/get-docker](https://docs.docker.com/get-docker/) | Container runtime |
| Docker Compose | ≥ 2.20 | Bundled with Docker Desktop | Multi-service orchestration |
| Git | ≥ 2.40 | [git-scm.com](https://git-scm.com/) | Version control |
| AWS CLI | ≥ 2.x | `brew install awscli` | AWS resource management |
| Terraform | ≥ 1.5 | `brew install terraform` | Infrastructure as Code |
| kubectl | ≥ 1.28 | `brew install kubectl` | Kubernetes management |
| Helm | ≥ 3.x | `brew install helm` | K8s package management |
| jq | ≥ 1.6 | `brew install jq` | JSON processing |

### Verify Installations

```bash
docker --version          # Docker version 24.x+
docker compose version    # Docker Compose version v2.20+
git --version             # git version 2.40+
aws --version             # aws-cli/2.x
terraform --version       # Terraform v1.5+
kubectl version --client  # Client Version: v1.28+
```

### AWS Configuration

```bash
# Configure AWS credentials
aws configure
#   AWS Access Key ID: <your-access-key>
#   AWS Secret Access Key: <your-secret-key>
#   Default region name: us-east-1
#   Default output format: json

# Verify access
aws sts get-caller-identity
```

---

## 2. Local Development (Docker Compose)

### 2.1 Clone & Configure

```bash
# Clone the repository
git clone https://github.com/neurosphere/neurosphere-platform.git
cd NeuroSphere

# Create environment configuration
cp .env.example .env

# Review and customise environment variables
# Key variables:
#   FLASK_ENV=development
#   LOG_LEVEL=DEBUG
#   GATEWAY_HOST_PORT=8080
#   MAX_ROBOT_VELOCITY=0.05
#   SAFETY_INTERLOCK_ENABLED=true
```

### 2.2 Build & Launch All Services

```bash
# Build all images and start in detached mode
docker compose up --build -d

# Expected output:
#   ✔ Network neurosphere-network Created
#   ✔ Container neurosphere-robot-command    Started
#   ✔ Container neurosphere-diagnostic-engine Started
#   ✔ Container neurosphere-patient-monitor  Started
#   ✔ Container neurosphere-telemetry-ingest Started
#   ✔ Container neurosphere-gateway          Started
```

### 2.3 Verify All Services Are Healthy

```bash
# Check container status (all should show "healthy")
docker compose ps

# Verify each service health endpoint
curl -s http://localhost:5050/health | jq .
curl -s http://localhost:3000/health | jq .
curl -s http://localhost:5001/health | jq .
curl -s http://localhost:5002/health | jq .
curl -s http://localhost:8080/health | jq .
```

### 2.4 Test Core Functionality

```bash
# Robot fleet status
curl -s http://localhost:5050/api/robots/status | jq '.fleet_size, .active_procedures'

# Send a robot command
curl -s -X POST http://localhost:5050/api/robots/command \
  -H "Content-Type: application/json" \
  -d '{"robot_id": "NSR-DA-VINCI-001", "command": "start_procedure", "parameters": {"procedure": "laparoscopic_cholecystectomy"}}' | jq .

# Patient vitals dashboard
curl -s http://localhost:5001/api/patients/dashboard | jq .

# Submit diagnostic analysis
curl -s -X POST http://localhost:3000/api/diagnostics/analyze \
  -H "Content-Type: application/json" \
  -d '{"patient_id": "PAT-001", "scan_type": "ct_scan", "body_region": "chest", "priority": "stat"}' | jq .

# Telemetry ingest
curl -s -X POST http://localhost:5002/api/telemetry/ingest \
  -H "Content-Type: application/json" \
  -d '{"source_id": "NSR-DA-VINCI-001", "source_type": "surgical_robot", "event_type": "heartbeat", "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'", "payload": {"battery": 95.2, "position": {"x": 0, "y": 0, "z": 0}}}' | jq .

# Telemetry stats
curl -s http://localhost:5002/api/telemetry/stats | jq .
```

### 2.5 View Logs

```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f robot-command-service

# Last 100 lines
docker compose logs --tail=100 patient-monitor-service
```

### 2.6 Stop Services

```bash
# Stop all services
docker compose down

# Stop and remove volumes
docker compose down -v

# Stop and remove images
docker compose down --rmi all
```

---

## 3. AWS Infrastructure Provisioning

### 3.1 Backend Setup (First-time Only)

Create the S3 bucket and DynamoDB table for Terraform state:

```bash
# Create S3 bucket for state
aws s3api create-bucket \
  --bucket neurosphere-terraform-state \
  --region us-east-1

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket neurosphere-terraform-state \
  --versioning-configuration Status=Enabled

# Enable encryption
aws s3api put-bucket-encryption \
  --bucket neurosphere-terraform-state \
  --server-side-encryption-configuration \
    '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "aws:kms"}}]}'

# Create DynamoDB table for state locking
aws dynamodb create-table \
  --table-name neurosphere-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

### 3.2 Initialize Terraform

```bash
cd infrastructure/terraform

# Initialize with backend configuration
terraform init

# For a specific environment:
terraform init -backend-config=environments/dev/backend.tf
```

### 3.3 Plan & Review

```bash
# Generate execution plan
terraform plan \
  -var-file=environments/dev/terraform.tfvars \
  -out=dev.tfplan

# Review the plan carefully — key resources:
#   + module.networking.aws_vpc.main
#   + module.networking.aws_subnet.private[*]
#   + module.security.aws_kms_key.main
#   + module.kubernetes.aws_eks_cluster.main
#   + module.kubernetes.aws_eks_node_group.main
#   + module.monitoring.aws_cloudwatch_log_group.main
```

### 3.4 Apply Infrastructure

```bash
# Apply the plan
terraform apply dev.tfplan

# Or apply directly (with auto-approve for non-production)
terraform apply \
  -var-file=environments/dev/terraform.tfvars \
  -auto-approve
```

### 3.5 Using the Makefile

```bash
# Simplified commands via Makefile
make init ENV=dev
make plan ENV=dev
make apply ENV=dev
make destroy ENV=dev
```

### 3.6 Retrieve Outputs

```bash
# Get EKS cluster name and endpoint
terraform output eks_cluster_name
terraform output eks_cluster_endpoint

# Get ECR repository URLs
terraform output ecr_repository_urls

# Configure kubectl
aws eks update-kubeconfig \
  --name $(terraform output -raw eks_cluster_name) \
  --region us-east-1
```

---

## 4. Kubernetes Deployment

### 4.1 Namespace Setup

```bash
# Create namespaces
kubectl apply -f kubernetes/namespaces/namespaces.yaml

# Verify
kubectl get namespaces | grep neurosphere
```

### 4.2 Deploy Core Services (Dev)

```bash
# Deploy using Kustomize dev overlay
kubectl apply -k kubernetes/overlays/dev/

# This deploys:
#   - ConfigMap (shared configuration)
#   - 5 Deployments (robot-command, diagnostic-engine, patient-monitor, telemetry-ingest, gateway)
#   - 5 Services (ClusterIP)
#   - HorizontalPodAutoscalers
#   - PodDisruptionBudgets
#   - NetworkPolicies
```

### 4.3 Deploy Core Services (Production)

```bash
# Deploy using Kustomize prod overlay
kubectl apply -k kubernetes/overlays/prod/

# Production overlay differences:
#   - Higher replica counts
#   - Larger resource limits
#   - Stricter network policies
```

### 4.4 Deploy Ingress Controller

```bash
# Deploy nginx ingress controller
kubectl apply -f kubernetes/ingress/nginx-ingress-controller.yaml

# Deploy ingress rules
kubectl apply -f kubernetes/ingress/ingress.yaml

# Get external endpoint
kubectl get ingress -n neurosphere
```

### 4.5 Verify Deployment

```bash
# Check all resources in namespace
kubectl get all -n neurosphere

# Check pod status (all should be Running)
kubectl get pods -n neurosphere -o wide

# Check service endpoints
kubectl get svc -n neurosphere

# Check HPA status
kubectl get hpa -n neurosphere

# Check PDB status
kubectl get pdb -n neurosphere

# Test from within cluster
kubectl run curl-test --rm -it --image=curlimages/curl -- \
  curl http://robot-command-service.neurosphere.svc:5000/health
```

### 4.6 Push Container Images to ECR

```bash
# Login to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-east-1.amazonaws.com

# Build and tag
for service in robot-command-service diagnostic-engine-service patient-monitor-service telemetry-ingest-service neurosphere-gateway; do
  docker build -t neurosphere/${service}:latest services/${service}/
  docker tag neurosphere/${service}:latest <account-id>.dkr.ecr.us-east-1.amazonaws.com/neurosphere/${service}:latest
  docker push <account-id>.dkr.ecr.us-east-1.amazonaws.com/neurosphere/${service}:latest
done
```

---

## 5. Monitoring Stack Setup

### 5.1 Local Monitoring (Docker Compose)

```bash
# Start the full monitoring stack
docker compose -f monitoring/docker-compose.monitoring.yml up -d

# Services started:
#   - Prometheus    :9090
#   - Grafana       :3001  (admin / neurosphere)
#   - Alertmanager  :9093
#   - Elasticsearch :9200
#   - Logstash      :5044
#   - Kibana        :5601
#   - Filebeat      (log shipper)
```

### 5.2 Verify Prometheus

```bash
# Check Prometheus is up
curl -s http://localhost:9090/-/healthy

# Check scrape targets are up
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health: .health}'

# Query a metric
curl -s 'http://localhost:9090/api/v1/query?query=up' | jq .
```

### 5.3 Access Grafana

1. Open browser to `http://localhost:3001`
2. Login with `admin` / `neurosphere`
3. Pre-provisioned dashboards are available under **Dashboards**:
   - **Robot Fleet** — Real-time fleet status, battery levels, emergency halts
   - **Patient Monitoring** — Vitals overview, alert timeline, ward occupancy
   - **Service Metrics** — Request rates, latency percentiles, error rates
   - **System Health** — Container resources, network I/O, uptime

### 5.4 Configure Alertmanager

Edit `monitoring/alertmanager/alertmanager.yml` to configure alert receivers:

```yaml
receivers:
  - name: 'slack-notifications'
    slack_configs:
      - api_url: 'https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK'
        channel: '#neurosphere-alerts'

  - name: 'pagerduty-critical'
    pagerduty_configs:
      - service_key: 'YOUR-PAGERDUTY-KEY'
```

### 5.5 Access Kibana (ELK Logs)

1. Open browser to `http://localhost:5601`
2. Create index pattern: `neurosphere-*`
3. Explore logs in **Discover** view
4. Filter by service: `service: "robot-command-service"`

---

## 6. Vault Initialization

### 6.1 Start Vault

```bash
# If running in Kubernetes:
kubectl apply -f security/vault/kubernetes/

# Verify Vault pod is running
kubectl get pods -n neurosphere -l app=vault
```

### 6.2 Initialize & Unseal

```bash
# Run the initialization script
chmod +x security/vault/scripts/init-vault.sh
./security/vault/scripts/init-vault.sh

# The script will:
#   1. Initialize Vault with 5 key shares, 3 key threshold
#   2. Unseal Vault using 3 of 5 keys
#   3. Authenticate with root token
#   4. Enable KV v2 secrets engine
#   5. Apply all policies
#   6. Seed initial secrets
```

### 6.3 Apply Policies

```bash
# Set Vault address
export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="<root-token>"

# Apply per-service policies
vault policy write neurosphere-admin security/vault/policies/neurosphere-admin.hcl
vault policy write neurosphere-services security/vault/policies/neurosphere-services.hcl
vault policy write neurosphere-cicd security/vault/policies/neurosphere-cicd.hcl
vault policy write neurosphere-robot-command security/vault/policies/neurosphere-robot-command.hcl
vault policy write neurosphere-patient-monitor security/vault/policies/neurosphere-patient-monitor.hcl

# Verify policies
vault policy list
```

### 6.4 Seed Secrets

```bash
# Seed initial secrets from template
vault kv put secret/neurosphere/database \
  host="neurosphere-db.cluster.us-east-1.rds.amazonaws.com" \
  port="5432" \
  username="neurosphere_app" \
  password="$(openssl rand -base64 32)"

vault kv put secret/neurosphere/robot-command \
  api_key="$(openssl rand -hex 32)" \
  safety_override_code="$(openssl rand -hex 16)"

vault kv put secret/neurosphere/patient-monitor \
  ehr_api_key="$(openssl rand -hex 32)" \
  notification_webhook="https://hooks.slack.com/..."
```

### 6.5 Enable Kubernetes Auth

```bash
# Enable K8s auth backend
vault auth enable kubernetes

# Configure with cluster info
vault write auth/kubernetes/config \
  kubernetes_host="https://$(kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}')" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

# Create roles for each service
vault write auth/kubernetes/role/robot-command \
  bound_service_account_names=robot-command-sa \
  bound_service_account_namespaces=neurosphere \
  policies=neurosphere-robot-command \
  ttl=1h
```

---

## 7. Jenkins CI/CD Setup

### 7.1 Start Jenkins

```bash
# Start Jenkins with Docker Compose
docker compose -f cicd/jenkins/docker-compose.jenkins.yml up -d

# Wait for Jenkins to initialize (check logs)
docker compose -f cicd/jenkins/docker-compose.jenkins.yml logs -f jenkins
```

### 7.2 Initial Configuration

1. Open browser to `http://localhost:8080`
2. Jenkins is pre-configured via JCasC (`config/jenkins.yaml`):
   - Admin user created automatically
   - Required plugins installed
   - Docker and Kubernetes cloud configured
   - Shared library loaded

### 7.3 Configure Credentials

Add the following credentials in Jenkins → Manage Jenkins → Credentials:

| Credential ID | Type | Purpose |
|--------------|------|---------|
| `aws-credentials` | AWS Credentials | ECR push, EKS deploy |
| `github-token` | Secret text | Repository access |
| `slack-webhook` | Secret text | Build notifications |
| `vault-token` | Secret text | Secrets retrieval |
| `sonarqube-token` | Secret text | Code quality analysis |

### 7.4 Create Pipeline Jobs

```bash
# The seed job automatically creates all pipelines:
# 1. Navigate to Jenkins → Manage Jenkins → Reload Configuration
# 2. Or trigger the seed job manually

# Created jobs:
#   - neurosphere-ci          (main CI pipeline — Jenkinsfile)
#   - neurosphere-deploy-dev  (dev deployment — Jenkinsfile.deploy)
#   - neurosphere-deploy-staging (staging deployment)
#   - neurosphere-deploy-prod (production deployment — manual approval)
```

### 7.5 Trigger a Build

```bash
# Option 1: Push to main branch (webhook trigger)
git push origin main

# Option 2: Manual trigger via CLI
curl -X POST http://localhost:8080/job/neurosphere-ci/build \
  --user admin:<api-token>

# Option 3: Jenkins UI → neurosphere-ci → Build Now
```

---

## 8. Post-Deployment Verification

### Verification Checklist

```
┌──────────────────────────────────────────────────────────────────────────┐
│                     DEPLOYMENT VERIFICATION CHECKLIST                     │
├──────────────────────────────────────────┬───────────────────────────────┤
│ Check                                    │ Command / URL                 │
├──────────────────────────────────────────┼───────────────────────────────┤
│ □ All pods running                       │ kubectl get pods -n neuro..   │
│ □ Robot Command healthy                  │ GET :5050/health              │
│ □ Diagnostic Engine healthy              │ GET :3000/health              │
│ □ Patient Monitor healthy                │ GET :5001/health              │
│ □ Telemetry Ingest healthy               │ GET :5002/health              │
│ □ Gateway healthy                        │ GET :8080/health              │
│ □ Robot fleet initialised                │ GET :5050/api/robots/status   │
│ □ Patients loaded                        │ GET :5001/api/patients/vitals │
│ □ Prometheus targets up                  │ GET :9090/api/v1/targets      │
│ □ Grafana dashboards loading             │ http://localhost:3001         │
│ □ Alertmanager reachable                 │ GET :9093/-/healthy           │
│ □ Vault initialised & unsealed           │ vault status                  │
│ □ Network policies applied               │ kubectl get netpol -n neuro.. │
│ □ HPA configured                         │ kubectl get hpa -n neuro..    │
│ □ PDB configured                         │ kubectl get pdb -n neuro..    │
│ □ Jenkins pipelines created              │ http://localhost:8080         │
│ □ Metrics exposed on /metrics            │ GET :5050/metrics             │
│ □ CORS headers present                   │ Check response headers       │
│ □ Rate limiting active                   │ Rapid requests → 429         │
│ □ Audit logs being generated             │ docker logs neurosphere-gw..  │
├──────────────────────────────────────────┴───────────────────────────────┤
│ □ ALL CHECKS PASSED — DEPLOYMENT VERIFIED                                │
└──────────────────────────────────────────────────────────────────────────┘
```

### Automated Verification Script

```bash
#!/bin/bash
# Quick smoke test for local Docker Compose deployment

SERVICES=(
  "http://localhost:5050/health:Robot Command"
  "http://localhost:3000/health:Diagnostic Engine"
  "http://localhost:5001/health:Patient Monitor"
  "http://localhost:5002/health:Telemetry Ingest"
  "http://localhost:8080/health:API Gateway"
)

echo "=== NeuroSphere Deployment Verification ==="
PASS=0
FAIL=0

for entry in "${SERVICES[@]}"; do
  URL="${entry%%:*}:${entry#*:}"
  URL="${entry%%:*}"
  NAME="${entry##*:}"

  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$URL" 2>/dev/null)
  if [ "$STATUS" = "200" ]; then
    echo "  ✅ $NAME — healthy (HTTP $STATUS)"
    ((PASS++))
  else
    echo "  ❌ $NAME — unhealthy (HTTP $STATUS)"
    ((FAIL++))
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && echo "🎉 All services are healthy!" || echo "⚠️  Some services need attention"
```

---

## 9. Live EC2 Deployment

NeuroSphere is deployed and running on AWS EC2. Below are the actual steps used.

### 9.1 EC2 Instance Details

| Attribute | Value |
|-----------|-------|
| **Instance Name** | `neurosphere-server` |
| **Instance ID** | `i-0b838d997334670f2` |
| **Instance Type** | `t3.small` |
| **Region** | `ap-south-1` (Mumbai) |
| **OS** | Amazon Linux 2023 |
| **Public IP** | `13.126.102.15` |

### 9.2 EC2 Provisioning Steps

```bash
# Launch EC2 instance
aws ec2 run-instances \
  --image-id ami-0e35ddab05955cf57 \
  --instance-type t3.small \
  --key-name neurosphere-key \
  --security-groups neurosphere-sg \
  --region ap-south-1 \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=neurosphere-server}]'

# Configure security group to allow all service ports
aws ec2 authorize-security-group-ingress \
  --group-name neurosphere-sg \
  --protocol tcp \
  --port 3000-9090 \
  --cidr 0.0.0.0/0 \
  --region ap-south-1
```

### 9.3 Deploy to EC2

```bash
# SSH into the instance
ssh -i neurosphere-key.pem ec2-user@13.126.102.15

# Install Docker and Docker Compose
sudo yum update -y
sudo yum install -y docker git
sudo systemctl enable docker && sudo systemctl start docker
sudo usermod -aG docker ec2-user

# Install Docker Compose plugin
sudo mkdir -p /usr/local/lib/docker/cli-plugins
sudo curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# Transfer project files (from local machine)
scp -i neurosphere-key.pem -r ./NeuroSphere ec2-user@13.126.102.15:~/

# Build and launch all services
cd ~/NeuroSphere
docker compose up --build -d
```

### 9.4 Live Verification

```bash
# Verify all 9 containers are running
ssh -i neurosphere-key.pem ec2-user@13.126.102.15 'docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'

# Test live endpoints from anywhere
curl -s http://13.126.102.15:5050/api/robots/status | jq '.fleet_size'
curl -s http://13.126.102.15:5001/api/patients/dashboard | jq '.total_patients'
curl -s http://13.126.102.15:3000/api/diagnostics/stats | jq '.accuracy_rate'
curl -s http://13.126.102.15:5002/api/telemetry/stats | jq '.events_per_second'
curl -s http://13.126.102.15:8080/health | jq .

# Access monitoring
# Grafana:    http://13.126.102.15:3001  (admin/neurosphere)
# Prometheus: http://13.126.102.15:9090
# Jenkins:    http://13.126.102.15:8081
# Dashboard:  http://13.126.102.15:3333
```

---

## 10. Troubleshooting FAQ

### Service Won't Start

**Symptom:** Container exits immediately or shows `unhealthy`.

```bash
# Check container logs
docker compose logs <service-name>

# Common causes:
# 1. Port already in use
lsof -i :5050   # Check if port is occupied
# Fix: Stop the conflicting process or change port in docker-compose.yml

# 2. Missing dependencies
docker compose up --build <service-name>   # Rebuild image

# 3. Health check failing
docker exec neurosphere-robot-command curl http://localhost:5000/health
```

### Docker Compose Build Fails

**Symptom:** `pip install` or `npm install` fails during build.

```bash
# Clear Docker build cache
docker builder prune -f

# Rebuild without cache
docker compose build --no-cache

# Check if you're behind a proxy
export HTTP_PROXY=http://proxy:port
export HTTPS_PROXY=http://proxy:port
```

### Terraform Plan Shows Unexpected Changes

**Symptom:** Terraform wants to destroy/recreate resources.

```bash
# Check state
terraform state list

# Refresh state from cloud
terraform refresh -var-file=environments/dev/terraform.tfvars

# Import existing resource
terraform import module.networking.aws_vpc.main vpc-xxxxxx
```

### Kubernetes Pods CrashLooping

**Symptom:** Pods show `CrashLoopBackOff` status.

```bash
# Check pod events
kubectl describe pod <pod-name> -n neurosphere

# Check pod logs
kubectl logs <pod-name> -n neurosphere --previous

# Common causes:
# 1. Image pull error → check ECR login
# 2. ConfigMap missing → kubectl get cm -n neurosphere
# 3. Resource limits too low → check HPA and resource requests
# 4. Health check failing → adjust initialDelaySeconds
```

### Prometheus Not Scraping Targets

**Symptom:** Targets show as `DOWN` in Prometheus.

```bash
# Check Prometheus config
curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.health != "up")'

# Common causes:
# 1. Service not exposing /metrics
curl http://localhost:5050/metrics   # Should return Prometheus format

# 2. Network issue (Docker)
docker network inspect neurosphere-network

# 3. Wrong scrape config
cat monitoring/prometheus/prometheus.yml | grep -A5 "job_name"
```

### Vault Sealed After Restart

**Symptom:** Services can't retrieve secrets, Vault shows `Sealed: true`.

```bash
# Check Vault status
vault status

# Unseal (need 3 of 5 keys)
vault operator unseal <key-1>
vault operator unseal <key-2>
vault operator unseal <key-3>

# For production, configure auto-unseal with AWS KMS
# (already configured in security/vault/config/vault-config.hcl)
```

### High Latency on API Calls

**Symptom:** Response times > 1 second.

```bash
# Check Prometheus for latency metrics
curl 'http://localhost:9090/api/v1/query?query=histogram_quantile(0.95,rate(robot_command_latency_seconds_bucket[5m]))'

# Check container resource usage
docker stats

# Common causes:
# 1. Container resource limits too low → increase in docker-compose.yml
# 2. Too many simulated robots/patients → adjust environment variables
# 3. Diagnostic engine processing backlog → check queue depth
```

### Rate Limiting Blocking Legitimate Traffic

**Symptom:** Receiving 429 responses.

```bash
# Check current rate limit config in nginx.conf
# Default: 10 req/s per IP, burst 20

# For testing, temporarily increase:
# Edit services/neurosphere-gateway/nginx.conf
#   limit_req_zone $binary_remote_addr zone=api_rate_limit:10m rate=50r/s;

# Rebuild gateway
docker compose up --build -d neurosphere-gateway
```

---

*For day-2 operations, see [Operations Runbook](runbook.md).*
*For architecture details, see [Architecture Guide](architecture.md).*
