# NeuroSphere — Operations Runbook

> Day-2 operations guide for managing, troubleshooting, and maintaining the NeuroSphere platform

---

## Table of Contents

1. [Common Tasks](#1-common-tasks)
2. [Secret Rotation with Vault](#2-secret-rotation-with-vault)
3. [Certificate Renewal](#3-certificate-renewal)
4. [Alert Response Runbooks](#4-alert-response-runbooks)
5. [Performance Tuning](#5-performance-tuning)
6. [Troubleshooting Guide](#6-troubleshooting-guide)
7. [Maintenance Procedures](#7-maintenance-procedures)
8. [EC2 Live Instance Operations](#8-ec2-live-instance-operations)

---

## 1. Common Tasks

### 1.1 Scaling Services

#### Kubernetes (Production)

```bash
# Scale a service manually
kubectl scale deployment robot-command -n neurosphere --replicas=5

# Check current HPA status
kubectl get hpa -n neurosphere

# Modify HPA limits
kubectl patch hpa robot-command-hpa -n neurosphere \
  --type='json' \
  -p='[{"op": "replace", "path": "/spec/maxReplicas", "value": 10}]'

# Watch scaling events
kubectl get events -n neurosphere --sort-by='.lastTimestamp' | grep -i scale
```

#### Docker Compose (Local)

```bash
# Scale a specific service
docker compose up -d --scale telemetry-ingest-service=3

# Note: When scaling behind the gateway, you'll need to update
# the nginx upstream block or use Docker DNS round-robin
```

### 1.2 Service Restarts

#### Kubernetes

```bash
# Rolling restart (zero-downtime)
kubectl rollout restart deployment robot-command -n neurosphere

# Watch rollout status
kubectl rollout status deployment robot-command -n neurosphere

# Rollback to previous version
kubectl rollout undo deployment robot-command -n neurosphere

# Rollback to specific revision
kubectl rollout undo deployment robot-command -n neurosphere --to-revision=3

# View rollout history
kubectl rollout history deployment robot-command -n neurosphere
```

#### Docker Compose

```bash
# Restart a specific service
docker compose restart robot-command-service

# Restart with rebuild
docker compose up -d --build robot-command-service

# Force recreate
docker compose up -d --force-recreate robot-command-service
```

### 1.3 Log Checking

#### Docker Compose

```bash
# Follow all logs
docker compose logs -f

# Specific service, last 200 lines
docker compose logs --tail=200 -f patient-monitor-service

# Search for errors
docker compose logs robot-command-service 2>&1 | grep -i error

# Search for a specific request ID
docker compose logs 2>&1 | grep "abc123-request-id"

# Export logs to file
docker compose logs --no-color > /tmp/neurosphere-logs-$(date +%Y%m%d).txt
```

#### Kubernetes

```bash
# Current pod logs
kubectl logs -l app=robot-command -n neurosphere -f

# Previous container logs (after restart)
kubectl logs <pod-name> -n neurosphere --previous

# All containers in a pod
kubectl logs <pod-name> -n neurosphere --all-containers

# Last 1 hour of logs
kubectl logs -l app=robot-command -n neurosphere --since=1h

# Search across all services
for svc in robot-command diagnostic-engine patient-monitor telemetry-ingest; do
  echo "=== $svc ==="
  kubectl logs -l app=$svc -n neurosphere --tail=50 | grep -i error
done
```

#### Kibana (ELK)

1. Open `http://localhost:5601`
2. Navigate to **Discover**
3. Select `neurosphere-*` index pattern
4. Use KQL queries:
   - `service: "robot-command-service" AND level: "ERROR"`
   - `robot_id: "NSR-DA-VINCI-001"`
   - `message: "emergency halt"`
   - `level: "ERROR" OR level: "CRITICAL"`

### 1.4 Checking Service Health

```bash
# Quick health check script
for service in \
  "http://localhost:5050/health:Robot Command" \
  "http://localhost:3000/health:Diagnostic Engine" \
  "http://localhost:5001/health:Patient Monitor" \
  "http://localhost:5002/health:Telemetry Ingest" \
  "http://localhost:8080/health:API Gateway"; do

  URL="${service%%:http*}"
  # Parse properly
  IFS=':' read -r PROTO HOST PORT REST <<< "$service"
  curl -s -o /dev/null -w "%{http_code}" "${PROTO}:${HOST}:${PORT}/${REST##*/}" 2>/dev/null
done

# Readiness check
for port in 5050 3000 5001 5002; do
  echo -n "Port $port: "
  curl -s http://localhost:$port/ready | jq -r '.status'
done

# Kubernetes readiness
kubectl get pods -n neurosphere -o wide
kubectl describe endpoints -n neurosphere
```

---

## 2. Secret Rotation with Vault

### 2.1 Rotate Database Credentials

```bash
export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="<admin-token>"

# Generate new password
NEW_PASSWORD=$(openssl rand -base64 32)

# Update in Vault
vault kv put secret/neurosphere/database \
  host="neurosphere-db.cluster.us-east-1.rds.amazonaws.com" \
  port="5432" \
  username="neurosphere_app" \
  password="$NEW_PASSWORD"

# Verify the update
vault kv get secret/neurosphere/database

# Rolling restart services to pick up new credentials
kubectl rollout restart deployment -n neurosphere -l tier=backend
```

### 2.2 Rotate API Keys

```bash
# Rotate robot command API key
vault kv put secret/neurosphere/robot-command \
  api_key="$(openssl rand -hex 32)" \
  safety_override_code="$(openssl rand -hex 16)"

# Rotate patient monitor EHR key
vault kv put secret/neurosphere/patient-monitor \
  ehr_api_key="$(openssl rand -hex 32)"

# Restart affected services
kubectl rollout restart deployment robot-command -n neurosphere
kubectl rollout restart deployment patient-monitor -n neurosphere
```

### 2.3 Rotate Vault Root Token

```bash
# Generate a new root token (requires unseal keys)
vault operator generate-root -init

# Provide unseal keys (need quorum of 3)
vault operator generate-root \
  -nonce=<nonce-from-init>

# Revoke old root token
vault token revoke <old-root-token>
```

### 2.4 Audit Secret Access

```bash
# Enable Vault audit logging
vault audit enable file file_path=/vault/logs/audit.log

# Check who accessed secrets
cat /vault/logs/audit.log | jq 'select(.request.path | contains("neurosphere"))'

# Check secret versions
vault kv metadata get secret/neurosphere/database
```

---

## 3. Certificate Renewal

### 3.1 TLS Certificate Renewal (ALB/Ingress)

```bash
# Check current certificate expiry
echo | openssl s_client -connect api.neurosphere.io:443 2>/dev/null | openssl x509 -noout -dates

# Using cert-manager (Kubernetes)
kubectl get certificate -n neurosphere
kubectl describe certificate neurosphere-tls -n neurosphere

# Force renewal
kubectl delete certificate neurosphere-tls -n neurosphere
# cert-manager will automatically re-issue

# Manual renewal with Let's Encrypt
certbot certonly --dns-route53 \
  -d "*.neurosphere.io" \
  -d "neurosphere.io"

# Update Kubernetes secret
kubectl create secret tls neurosphere-tls \
  --cert=fullchain.pem \
  --key=privkey.pem \
  -n neurosphere \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 3.2 Vault TLS Certificate Renewal

```bash
# Generate new Vault server certificate
openssl req -new -newkey rsa:4096 -nodes \
  -keyout vault-server.key \
  -out vault-server.csr \
  -subj "/CN=vault.neurosphere.svc"

# Sign with internal CA (or submit to external CA)
# Update Vault configuration
kubectl create secret tls vault-tls \
  --cert=vault-server.crt \
  --key=vault-server.key \
  -n neurosphere \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart Vault
kubectl rollout restart statefulset vault -n neurosphere
```

---

## 4. Alert Response Runbooks

### 4.1 Alert: `RobotHeartbeatLost`

**Severity:** CRITICAL
**Condition:** Robot heartbeat status = 0 for > 30 seconds

**Response:**
```
1. CHECK: Verify alert is genuine
   kubectl logs -l app=robot-command -n neurosphere --tail=50 | grep -i heartbeat

2. ASSESS: Determine which robot(s) are affected
   curl -s http://localhost:5050/api/robots/heartbeat | jq '.heartbeat | to_entries[] | select(.value.online == false)'

3. CHECK: Is the robot physically powered on?
   - Contact hospital biomedical engineering
   - Check network connectivity to robot

4. ATTEMPT RECOVERY:
   curl -s http://localhost:5050/api/robots/heartbeat  # Trigger recovery (10% per check)

5. ESCALATE if not recovered within 5 minutes:
   - Notify on-call biomedical engineer
   - If robot was mid-procedure, activate backup manual control
   - Page surgical team lead

6. DOCUMENT: Create incident record with timeline
```

### 4.2 Alert: `PatientSpO2Critical`

**Severity:** CRITICAL
**Condition:** Patient SpO₂ < 88% for > 15 seconds

**Response:**
```
1. IMMEDIATE: This is a clinical emergency simulation
   - Alert is from the simulated vitals generator
   - In production: immediate bedside nurse notification

2. CHECK: Verify which patient is affected
   curl -s http://localhost:5001/api/patients/alerts?severity=CRITICAL | jq .

3. CHECK: Review patient vitals trend
   curl -s http://localhost:5001/api/patients/history/<patient_id>?limit=20 | jq .

4. SYSTEM CHECK: Is the vitals simulator functioning correctly?
   curl -s http://localhost:5001/ready | jq .

5. RESET if needed:
   docker compose restart patient-monitor-service
```

### 4.3 Alert: `HighDiagnosticQueueDepth`

**Severity:** WARNING
**Condition:** Diagnostic queue pending > 20 jobs

**Response:**
```
1. CHECK queue status:
   curl -s http://localhost:3000/api/diagnostics/queue | jq .

2. CHECK processing rate:
   curl -s http://localhost:3000/api/diagnostics/stats | jq '.throughput_per_minute'

3. SCALE if in Kubernetes:
   kubectl scale deployment diagnostic-engine -n neurosphere --replicas=3

4. CHECK for stuck jobs:
   curl -s http://localhost:3000/api/diagnostics/queue | jq '.recent_jobs[] | select(.status == "processing")'

5. If jobs are stuck, restart the service:
   kubectl rollout restart deployment diagnostic-engine -n neurosphere
```

### 4.4 Alert: `HighTelemetryErrorRate`

**Severity:** WARNING
**Condition:** Telemetry error rate > 5% over 5 minutes

**Response:**
```
1. CHECK error details:
   curl -s http://localhost:5002/api/telemetry/errors?limit=20 | jq .

2. CHECK which sources are causing errors:
   curl -s http://localhost:5002/api/telemetry/health-summary | jq '.error_rates_by_source'

3. CHECK buffer status:
   curl -s http://localhost:5002/api/telemetry/stats | jq '{buffer_size, buffer_capacity, error_rate}'

4. If buffer is near capacity:
   - Increase buffer size (restart with BUFFER_CAPACITY env var)
   - Scale telemetry service replicas

5. If specific source is faulty:
   - Check source device logs
   - Validate payload format being sent
```

### 4.5 Alert: `HighLatency` (Any Service)

**Severity:** WARNING
**Condition:** p95 latency > 2 seconds for 5+ minutes

**Response:**
```
1. IDENTIFY affected service:
   - Check Grafana Service Metrics dashboard
   - Or query Prometheus:
   curl 'http://localhost:9090/api/v1/query?query=histogram_quantile(0.95,rate(robot_command_latency_seconds_bucket[5m]))'

2. CHECK resource usage:
   docker stats --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"

3. CHECK for resource throttling:
   kubectl top pods -n neurosphere

4. ACTIONS:
   - If CPU-bound: increase CPU limits or scale replicas
   - If memory-bound: increase memory limits, check for leaks
   - If I/O-bound: check disk usage, log volume
   - If network-bound: check network policies, DNS resolution

5. SCALE:
   kubectl scale deployment <service> -n neurosphere --replicas=<N>
```

### 4.6 Alert: `PodCrashLooping`

**Severity:** CRITICAL
**Condition:** Pod restart count > 5 in 10 minutes

**Response:**
```
1. IDENTIFY the crashing pod:
   kubectl get pods -n neurosphere | grep -v Running

2. CHECK logs from previous container:
   kubectl logs <pod-name> -n neurosphere --previous

3. CHECK pod events:
   kubectl describe pod <pod-name> -n neurosphere | tail -20

4. COMMON CAUSES:
   a. OOMKilled → increase memory limits
   b. Liveness probe failing → check health endpoint
   c. Configuration error → check ConfigMap, env vars
   d. Image pull error → check ECR credentials

5. FIX:
   # If ConfigMap issue:
   kubectl get configmap -n neurosphere -o yaml

   # If resource issue:
   kubectl patch deployment <name> -n neurosphere \
     --type='json' \
     -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/memory", "value": "512Mi"}]'

   # If image issue:
   kubectl set image deployment/<name> <container>=<new-image> -n neurosphere
```

---

## 5. Performance Tuning

### 5.1 Service-Specific Tuning

#### Robot Command Service

| Parameter | Default | Tuning Guidance |
|-----------|---------|-----------------|
| `MAX_ROBOT_VELOCITY` | 0.05 m/s | Increase for faster simulation, max 0.15 |
| `SAFETY_INTERLOCK_ENABLED` | true | Never disable in production |
| CPU limit | 0.50 | Increase to 1.0 for large fleets (20+ robots) |
| Memory limit | 256M | Sufficient for up to 50 robots |

#### Diagnostic Engine Service

| Parameter | Default | Tuning Guidance |
|-----------|---------|-----------------|
| `MAX_CONCURRENT_ANALYSES` | 4 | Increase to 8 with sufficient CPU |
| `MODEL_CONFIDENCE_THRESHOLD` | 0.85 | Lower for more results, raise for precision |
| CPU limit | 1.00 | AI processing is CPU-intensive, use up to 2.0 |
| Memory limit | 512M | Increase to 1G for concurrent high-res imaging |

#### Patient Monitor Service

| Parameter | Default | Tuning Guidance |
|-----------|---------|-----------------|
| `ANOMALY_RATE` | 0.05 | Increase for testing alerts (max 0.30) |
| `VITALS_UPDATE_INTERVAL` | 3s | Decrease for higher fidelity simulation (min 1s) |
| `HEART_RATE_CRITICAL_LOW` | 40 | Clinical standard, adjust per protocol |
| `SPO2_CRITICAL_LOW` | 88 | Clinical standard, adjust per protocol |

#### Telemetry Ingest Service

| Parameter | Default | Tuning Guidance |
|-----------|---------|-----------------|
| `INGEST_BATCH_SIZE` | 100 | Increase to 500 for high-throughput |
| `INGEST_FLUSH_INTERVAL_MS` | 5000 | Decrease for lower latency (min 1000) |
| `MAX_TELEMETRY_AGE_SECONDS` | 300 | Increase for longer retention |
| Buffer capacity | 10,000 | Increase for high-volume environments |

### 5.2 Gateway Tuning

```nginx
# For high-traffic environments, adjust in nginx.conf:

# Increase worker connections
worker_connections 4096;

# Increase rate limit
limit_req_zone $binary_remote_addr zone=api_rate_limit:10m rate=100r/s;

# Increase upstream keepalive
upstream robot_command {
    server robot-command-service:5000;
    keepalive 64;  # Up from 16
}

# Increase buffer sizes for large payloads
proxy_buffer_size 16k;
proxy_buffers 8 32k;
```

### 5.3 Prometheus Tuning

```yaml
# Adjust scrape interval for high-cardinality services
# monitoring/prometheus/prometheus.yml

scrape_configs:
  - job_name: 'telemetry-ingest'
    scrape_interval: 5s    # Faster for real-time metrics
    scrape_timeout: 3s

  - job_name: 'robot-command'
    scrape_interval: 10s   # Standard interval

# Increase retention
# monitoring/docker-compose.monitoring.yml
command:
  - '--storage.tsdb.retention.time=30d'  # Up from 15d
  - '--storage.tsdb.retention.size=10GB'
```

---

## 6. Troubleshooting Guide

### 6.1 Service Won't Start

```bash
# Step 1: Check logs
docker compose logs <service-name> | tail -50

# Step 2: Check for port conflicts
lsof -i :5050 -i :3000 -i :5001 -i :5002 -i :8080

# Step 3: Check Docker resources
docker system df
docker system prune -f   # Clean unused resources

# Step 4: Rebuild from scratch
docker compose down -v
docker compose build --no-cache
docker compose up -d
```

### 6.2 High Latency Investigation

```bash
# Step 1: Identify which service is slow
for port in 5050 3000 5001 5002; do
  echo -n "Port $port: "
  curl -o /dev/null -s -w "%{time_total}s\n" http://localhost:$port/health
done

# Step 2: Check container resource usage
docker stats --no-stream

# Step 3: Check Prometheus latency metrics
curl -s 'http://localhost:9090/api/v1/query?query=histogram_quantile(0.95,rate(robot_command_latency_seconds_bucket[5m]))' | jq '.data.result[].value[1]'

# Step 4: Profile network latency
docker exec neurosphere-robot-command ping -c 3 telemetry-ingest-service

# Step 5: Check DNS resolution
docker exec neurosphere-gateway nslookup robot-command-service
```

### 6.3 Disk Full

```bash
# Step 1: Check disk usage
df -h

# Step 2: Docker-specific cleanup
docker system prune -a --volumes -f
docker builder prune -f

# Step 3: Clean old logs
docker compose logs --no-color > /dev/null  # Truncate

# Step 4: Clean Prometheus data
# Restart Prometheus with reduced retention:
# --storage.tsdb.retention.time=7d

# Step 5: Clean Elasticsearch indices
curl -X DELETE "http://localhost:9200/neurosphere-$(date -d '30 days ago' +%Y.%m)*"
```

### 6.4 Service Cannot Connect to Other Services

```bash
# Step 1: Check Docker network
docker network inspect neurosphere-network

# Step 2: Verify DNS resolution
docker exec neurosphere-robot-command getent hosts patient-monitor-service

# Step 3: Check if target service is healthy
docker compose ps

# Step 4: Test connectivity
docker exec neurosphere-gateway wget -qO- http://robot-command-service:5000/health

# Step 5: Check network policies (Kubernetes)
kubectl get networkpolicy -n neurosphere -o yaml
```

### 6.5 Prometheus Alerts Firing Unexpectedly

```bash
# Step 1: Check alert status
curl -s http://localhost:9090/api/v1/alerts | jq '.data.alerts[] | {alertname: .labels.alertname, state: .state}'

# Step 2: Check the underlying metric
curl -s 'http://localhost:9090/api/v1/query?query=up{job="robot-command"}' | jq .

# Step 3: Silence alert temporarily
# Use Alertmanager UI: http://localhost:9093/#/silences
# Or via API:
curl -X POST http://localhost:9093/api/v2/silences \
  -H "Content-Type: application/json" \
  -d '{
    "matchers": [{"name": "alertname", "value": "TestAlert", "isRegex": false}],
    "startsAt": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
    "endsAt": "'$(date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%SZ)'",
    "createdBy": "ops-team",
    "comment": "Investigating false positive"
  }'
```

---

## 7. Maintenance Procedures

### 7.1 Scheduled Maintenance Window

```
Pre-Maintenance Checklist:
□ Notify stakeholders (clinical simulation team, DevOps)
□ Verify backup is current (check CronJob last run)
□ Check no active procedures: curl http://localhost:5050/api/robots/status | jq '.active_procedures'
□ Verify all PDBs are in place: kubectl get pdb -n neurosphere

During Maintenance:
□ Apply changes (rolling update preferred)
□ Monitor rollout: kubectl rollout status deployment/<name> -n neurosphere
□ Watch for alerts in Grafana/Alertmanager

Post-Maintenance:
□ Run verification checklist (see deployment-guide.md §8)
□ Verify all services healthy
□ Check Prometheus targets are UP
□ Monitor for 30 minutes for regressions
□ Send completion notification
```

### 7.2 Docker Image Updates

```bash
# Update base images
# 1. Update Dockerfile FROM directives
# 2. Rebuild all images
docker compose build --no-cache

# 3. Security scan new images
for service in robot-command-service diagnostic-engine-service patient-monitor-service telemetry-ingest-service; do
  docker run --rm aquasec/trivy image neurosphere/$service:latest
done

# 4. Deploy updated images
docker compose up -d
```

### 7.3 Backup Verification

```bash
# Run manual backup
./disaster-recovery/scripts/backup-databases.sh
./disaster-recovery/scripts/backup-etcd.sh
./disaster-recovery/scripts/backup-vault.sh

# Verify backups in S3
aws s3 ls s3://neurosphere-backups/ --recursive | tail -10

# Test restore (in isolated environment)
./disaster-recovery/scripts/restore-cluster.sh --dry-run
```

### 7.4 Capacity Planning

```bash
# Check current resource usage trends
# Grafana → System Health dashboard → Resource Usage panel

# Key metrics to track:
# - CPU request vs. actual usage per service
# - Memory request vs. actual usage per service
# - Telemetry buffer utilization (should stay < 80%)
# - Diagnostic queue depth trend
# - Pod restart counts

# Query Prometheus for resource trends
# CPU usage trend (7 days)
curl 'http://localhost:9090/api/v1/query_range?query=rate(container_cpu_usage_seconds_total{namespace="neurosphere"}[5m])&start=2026-06-13T00:00:00Z&end=2026-06-20T00:00:00Z&step=3600'

# Memory usage trend (7 days)
curl 'http://localhost:9090/api/v1/query_range?query=container_memory_usage_bytes{namespace="neurosphere"}&start=2026-06-13T00:00:00Z&end=2026-06-20T00:00:00Z&step=3600'
```

---

*For architecture details, see [Architecture Guide](architecture.md).*
*For deployment instructions, see [Deployment Guide](deployment-guide.md).*
*For API documentation, see [API Reference](api-reference.md).*

---

## 8. EC2 Live Instance Operations

### 8.1 Instance Details

| Attribute | Value |
|-----------|-------|
| **Instance Name** | `neurosphere-server` |
| **Instance ID** | `i-0b838d997334670f2` |
| **Instance Type** | `t3.small` |
| **Region** | `ap-south-1` (Mumbai) |
| **OS** | Amazon Linux 2023 |
| **Public IP** | `13.126.102.15` |
| **Containers** | 9 running |

### 8.2 SSH Access

```bash
# SSH into the EC2 instance
ssh -i neurosphere-key.pem ec2-user@13.126.102.15

# Check running containers
ssh -i neurosphere-key.pem ec2-user@13.126.102.15 'docker ps'

# View all container logs
ssh -i neurosphere-key.pem ec2-user@13.126.102.15 'docker compose logs --tail=50'

# Restart all services
ssh -i neurosphere-key.pem ec2-user@13.126.102.15 'cd ~/NeuroSphere && docker compose restart'

# Restart a specific service
ssh -i neurosphere-key.pem ec2-user@13.126.102.15 'cd ~/NeuroSphere && docker compose restart robot-command-service'
```

### 8.3 Live Health Checks

```bash
# Quick health check from your local machine
for endpoint in \
  "http://13.126.102.15:5050/health" \
  "http://13.126.102.15:3000/health" \
  "http://13.126.102.15:5001/health" \
  "http://13.126.102.15:5002/health" \
  "http://13.126.102.15:8080/health"; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$endpoint" 2>/dev/null)
  echo "$endpoint → HTTP $STATUS"
done

# Full service verification
curl -s http://13.126.102.15:5050/api/robots/status | jq '.fleet_size, .active_procedures'
curl -s http://13.126.102.15:5001/api/patients/dashboard | jq '.total_patients, .critical_alerts'
curl -s http://13.126.102.15:3000/api/diagnostics/stats | jq '.accuracy_rate'
curl -s http://13.126.102.15:5002/api/telemetry/stats | jq '.events_per_second'
```

### 8.4 EC2 Troubleshooting

```bash
# Check instance status via AWS CLI
aws ec2 describe-instance-status \
  --instance-ids i-0b838d997334670f2 \
  --region ap-south-1 | jq '.InstanceStatuses[0].InstanceState'

# Check Docker disk usage on EC2
ssh -i neurosphere-key.pem ec2-user@13.126.102.15 'docker system df'

# Rebuild and redeploy (after pushing code changes)
ssh -i neurosphere-key.pem ec2-user@13.126.102.15 'cd ~/NeuroSphere && git pull && docker compose up --build -d'

# View container resource usage
ssh -i neurosphere-key.pem ec2-user@13.126.102.15 'docker stats --no-stream'

# Check EC2 instance system resources
ssh -i neurosphere-key.pem ec2-user@13.126.102.15 'free -h && df -h'

# Emergency: Stop all containers
ssh -i neurosphere-key.pem ec2-user@13.126.102.15 'cd ~/NeuroSphere && docker compose down'

# Emergency: Reboot instance
aws ec2 reboot-instances --instance-ids i-0b838d997334670f2 --region ap-south-1
```

### 8.5 Live Monitoring URLs

| Service | URL | Notes |
|---------|-----|-------|
| Dashboard | http://13.126.102.15:3333 | Main NeuroSphere dashboard |
| Grafana | http://13.126.102.15:3001 | Login: `admin` / `neurosphere` |
| Jenkins | http://13.126.102.15:8081 | CI/CD pipeline console |
| Prometheus | http://13.126.102.15:9090 | Metrics & alerting |
| Robot API | http://13.126.102.15:5050/api/robots/status | Surgical robot fleet |
| Patient API | http://13.126.102.15:5001/api/patients/dashboard | Patient monitoring |
| Diagnostics API | http://13.126.102.15:3000/api/diagnostics/stats | AI diagnostics |
| Telemetry API | http://13.126.102.15:5002/api/telemetry/stats | IoT telemetry |
| Gateway | http://13.126.102.15:8080/health | API gateway |
