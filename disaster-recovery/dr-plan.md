# NeuroSphere Medical Robotics — Disaster Recovery Plan

> **Classification:** CONFIDENTIAL — Internal Use Only  
> **Owner:** Platform Engineering & SRE  
> **Last Updated:** 2026-06-20  
> **Review Cadence:** Quarterly  
> **Approved By:** VP Engineering, CISO, Chief Medical Officer  
> **Document Version:** 2.0

---

## Table of Contents

1. [Overview](#1-overview)
2. [RTO/RPO Targets](#2-rtorpo-targets)
3. [Architecture Overview](#3-architecture-overview)
4. [Backup Strategy](#4-backup-strategy)
5. [Disaster Scenarios & Runbooks](#5-disaster-scenarios--runbooks)
6. [Escalation Matrix](#6-escalation-matrix)
7. [Communication Templates](#7-communication-templates)
8. [DR Testing Schedule](#8-dr-testing-schedule)
9. [Compliance & Regulatory](#9-compliance--regulatory)
10. [Appendices](#10-appendices)

---

## 1. Overview

### 1.1 Purpose

This document defines the Disaster Recovery (DR) strategy for the NeuroSphere Medical Robotics platform. NeuroSphere controls surgical robotic systems and monitors patient vitals in real-time. System failures can have **life-safety implications**, making DR planning a critical operational and regulatory requirement.

### 1.2 Scope

| In Scope | Out of Scope |
|----------|-------------|
| All NeuroSphere microservices | Physical robot hardware failures |
| Kubernetes cluster infrastructure | Hospital network infrastructure |
| PostgreSQL databases (robot-db, patient-db, telemetry-db) | Third-party EHR integrations |
| HashiCorp Vault secrets management | End-user device management |
| Monitoring & observability stack | On-premise equipment |
| DNS & load balancing | |

### 1.3 Key Assumptions

- Multi-region AWS deployment (primary: `us-east-1`, DR: `us-west-2`)
- Kubernetes (EKS) with multi-AZ node groups
- RDS PostgreSQL with cross-region read replicas
- Vault with Raft storage backend and DR replication
- All backups encrypted and stored in S3 with cross-region replication

---

## 2. RTO/RPO Targets

### 2.1 Service-Level Recovery Objectives

| Service | RPO | RTO | Priority | Justification |
|---------|-----|-----|----------|---------------|
| **Patient Monitor** | 1 min | 5 min | **P0** (life-critical) | Real-time vital signs monitoring; gaps risk patient safety |
| **Robot Command** | 5 min | 10 min | **P0** (safety-critical) | Active surgical robot control; must fail-safe immediately |
| **Diagnostic Engine** | 15 min | 30 min | **P1** (clinically important) | AI-assisted diagnostics; deferred analysis acceptable briefly |
| **Telemetry Ingest** | 30 min | 60 min | **P2** (operationally important) | Sensor data pipeline; buffered at source, replay supported |
| **Gateway (API)** | N/A | 5 min | **P1** (access critical) | Stateless routing layer; no data loss, fast replacement |

### 2.2 Infrastructure Recovery Objectives

| Component | RPO | RTO | Strategy |
|-----------|-----|-----|----------|
| Kubernetes Cluster | 24 hr | 30 min | etcd snapshot + IaC rebuild |
| PostgreSQL (patient-db) | 1 min | 15 min | Streaming replication + PITR |
| PostgreSQL (robot-db) | 5 min | 15 min | Streaming replication + PITR |
| PostgreSQL (telemetry-db) | 30 min | 30 min | Daily snapshot + WAL archive |
| Vault | 24 hr | 15 min | Raft snapshot + DR replication |
| DNS/Load Balancer | N/A | 2 min | Route53 health check failover |

### 2.3 Priority Definitions

| Priority | Definition | Response Time | Escalation |
|----------|-----------|---------------|------------|
| **P0** | Life-safety or safety-critical system down | Immediate | VP Eng + CMO within 5 min |
| **P1** | Core clinical functionality degraded | < 15 min | Engineering Lead within 15 min |
| **P2** | Operational system impaired | < 30 min | On-call engineer within 30 min |
| **P3** | Non-critical system issue | < 4 hr | Next business day |

---

## 3. Architecture Overview

### 3.1 Multi-Region Topology

```
┌─────────────────────────────────────────────────────────────────┐
│                     Route53 (Health-Check DNS)                  │
│                    api.neurosphere.io                           │
└────────────────────┬───────────────────────┬────────────────────┘
                     │ Primary               │ Failover
          ┌──────────▼──────────┐  ┌─────────▼──────────┐
          │   us-east-1         │  │   us-west-2 (DR)   │
          │                     │  │                     │
          │  ┌───────────────┐  │  │  ┌───────────────┐  │
          │  │  EKS Cluster  │  │  │  │  EKS Cluster  │  │
          │  │  (3 AZs)      │  │  │  │  (3 AZs)      │  │
          │  └───────────────┘  │  │  └───────────────┘  │
          │                     │  │                     │
          │  ┌───────────────┐  │  │  ┌───────────────┐  │
          │  │  RDS Primary  │──┼──┼──│  RDS Replica   │  │
          │  │  (Multi-AZ)   │  │  │  │  (Read-only)   │  │
          │  └───────────────┘  │  │  └───────────────┘  │
          │                     │  │                     │
          │  ┌───────────────┐  │  │  ┌───────────────┐  │
          │  │  Vault (Raft) │──┼──┼──│  Vault (DR)    │  │
          │  │  3-node        │  │  │  │  Performance   │  │
          │  └───────────────┘  │  │  └───────────────┘  │
          │                     │  │                     │
          │  ┌───────────────┐  │  │  ┌───────────────┐  │
          │  │  S3 Backups   │──┼──┼──│  S3 Replica    │  │
          │  └───────────────┘  │  │  └───────────────┘  │
          └─────────────────────┘  └─────────────────────┘
```

### 3.2 Data Flow During Normal Operations

1. All writes go to primary region (`us-east-1`)
2. RDS streaming replication to DR read replicas (async, < 1 min lag)
3. Vault DR replication to `us-west-2` performance standby
4. S3 cross-region replication for backups
5. Telemetry data buffered in Kafka with 24h retention

---

## 4. Backup Strategy

### 4.1 Backup Schedule

| Component | Method | Frequency | Retention | Storage |
|-----------|--------|-----------|-----------|---------|
| etcd | `etcdctl snapshot` | Daily 02:00 UTC | 30 snapshots | S3 (SSE-KMS) |
| Vault | `vault operator raft snapshot` | Daily 02:00 UTC | 30 snapshots | S3 (SSE-KMS) |
| patient-db | `pg_dump` + GPG | Daily 02:00 UTC | 30 days active, Glacier 90d | S3 (SSE-KMS) |
| robot-db | `pg_dump` + GPG | Daily 02:00 UTC | 30 days active, Glacier 90d | S3 (SSE-KMS) |
| telemetry-db | `pg_dump` + GPG | Daily 02:00 UTC | 30 days active, Glacier 90d | S3 (SSE-KMS) |
| WAL Archives | Continuous | Continuous | 7 days | S3 (SSE-KMS) |

### 4.2 Backup Encryption

| Layer | Method | Key Management |
|-------|--------|----------------|
| Application | GPG (asymmetric, RSA-4096) | Keys in Vault, backup in HSM |
| Transport | TLS 1.3 | AWS Certificate Manager |
| Storage | S3 SSE-KMS | AWS KMS (CMK, auto-rotation) |

### 4.3 Backup Verification

- **Automated:** Daily checksum verification after upload
- **Monthly:** Restore single database to isolated environment
- **Quarterly:** Full restore drill in DR region

---

## 5. Disaster Scenarios & Runbooks

---

### Scenario 1: Single Pod Failure

**Severity:** Low | **Priority:** P3 | **Auto-Recovery:** Yes

**Description:** A single pod crashes or becomes unresponsive.

**Detection:**
- Kubernetes liveness probe failure
- Prometheus alert: `KubePodCrashLooping`

**Recovery (Automated):**
```
Pod crash detected
    │
    ├── Kubernetes restarts pod (restartPolicy: Always)
    │   └── Pod healthy? ──→ Yes ──→ Done ✓
    │                      └── No (CrashLoopBackOff)
    │
    ├── Check recent deployments
    │   └── Rollback? ──→ kubectl rollout undo
    │
    └── Escalate to on-call if pod fails > 5 restarts in 10 min
```

**Runbook:**
1. **Verify:** `kubectl get pods -n neurosphere-production -l app=<service>`
2. **Check logs:** `kubectl logs <pod> -n neurosphere-production --previous`
3. **Check events:** `kubectl describe pod <pod> -n neurosphere-production`
4. **If OOMKilled:** Review memory limits, check for memory leaks
5. **If CrashLoopBackOff:** Check application logs, recent config changes
6. **Rollback if needed:** `kubectl rollout undo deployment/<service> -n neurosphere-production`

**Estimated Recovery:** < 1 minute (automatic)

---

### Scenario 2: Node Failure

**Severity:** Medium | **Priority:** P2 | **Auto-Recovery:** Partial

**Description:** An EC2 worker node becomes unavailable (hardware failure, spot termination, OS crash).

**Detection:**
- Node status: `NotReady`
- Prometheus alert: `KubeNodeNotReady`
- AWS EC2 status check failure

**Decision Tree:**
```
Node NotReady detected
    │
    ├── Single node? ──→ Yes
    │   ├── Pods rescheduled to healthy nodes (PDB enforced)
    │   ├── Cluster Autoscaler provisions replacement node
    │   └── Verify all pods running: kubectl get pods -o wide
    │
    ├── Multiple nodes? ──→ Possible AZ issue
    │   ├── Check AWS Health Dashboard
    │   ├── Check if nodes are in same AZ
    │   └── Escalate to Scenario 3 if AZ-wide
    │
    └── All nodes? ──→ Major infrastructure failure
        └── Escalate to Scenario 4
```

**Runbook:**
1. **Assess scope:** `kubectl get nodes` — how many nodes affected?
2. **Check AWS:** `aws ec2 describe-instance-status --region us-east-1`
3. **Verify PDB enforcement:** `kubectl get pdb -n neurosphere-production`
4. **Check pod redistribution:** `kubectl get pods -n neurosphere-production -o wide`
5. **Monitor cluster autoscaler:** `kubectl logs -n kube-system -l app=cluster-autoscaler`
6. **Cordon unhealthy node:** `kubectl cordon <node>` (if not already)
7. **Drain if needed:** `kubectl drain <node> --grace-period=30 --force`

**Estimated Recovery:** 2-5 minutes (pod rescheduling) + 3-5 minutes (new node)

---

### Scenario 3: Availability Zone Failure

**Severity:** High | **Priority:** P1 | **Auto-Recovery:** Partial

**Description:** An entire AWS Availability Zone becomes unavailable.

**Detection:**
- Multiple nodes in same AZ become `NotReady`
- AWS Health Dashboard AZ advisory
- Cross-AZ latency spikes

**Runbook:**
1. **Confirm AZ failure:**
   ```bash
   kubectl get nodes -o custom-columns=NAME:.metadata.name,AZ:.metadata.labels."topology\.kubernetes\.io/zone",STATUS:.status.conditions[-1].type
   ```
2. **Verify pod redistribution across remaining AZs:**
   ```bash
   kubectl get pods -n neurosphere-production -o wide | grep -v <failed-az>
   ```
3. **Check PodDisruptionBudgets are honored:**
   ```bash
   kubectl get pdb -n neurosphere-production
   ```
4. **Scale up nodes in healthy AZs if needed:**
   ```bash
   aws autoscaling update-auto-scaling-group \
     --auto-scaling-group-name neurosphere-production-nodes \
     --desired-capacity <current+N>
   ```
5. **Verify RDS Multi-AZ failover:**
   ```bash
   aws rds describe-db-instances --db-instance-identifier neurosphere-production-patient-db \
     --query 'DBInstances[0].AvailabilityZone'
   ```
6. **Monitor service health endpoints** — all P0 services must be healthy within 10 min
7. **Notify stakeholders** using Communication Template A

**Estimated Recovery:** 5-15 minutes

---

### Scenario 4: Region Failure

**Severity:** Critical | **Priority:** P0 | **Auto-Recovery:** No (manual trigger)

**Description:** Entire AWS region (`us-east-1`) becomes unavailable.

**Detection:**
- All health check endpoints unreachable
- Route53 health checks failing
- AWS global status page confirms regional issue

**Decision Tree:**
```
Region failure confirmed
    │
    ├── Duration estimate < 30 min? ──→ Wait and monitor
    │   └── Set 15-min reassessment timer
    │
    ├── Duration unknown or > 30 min?
    │   ├── ACTIVATE DR FAILOVER
    │   ├── Execute: ./dr-failover.sh --environment production --force
    │   └── Follow steps below
    │
    └── P0 services affected?
        └── Yes ──→ IMMEDIATE FAILOVER (no wait)
```

**Runbook:**
1. **Confirm region failure** — check AWS Health Dashboard, try multiple endpoints
2. **Assemble incident response team** (see Escalation Matrix)
3. **Decision: Activate DR?** — If P0 services affected, activate immediately
4. **Execute automated failover:**
   ```bash
   ./disaster-recovery/scripts/dr-failover.sh \
     --environment production \
     --force
   ```
5. **Verify DR region:**
   - DNS resolution: `dig api.neurosphere.io`
   - Health checks: `curl https://api-dr.neurosphere.internal/health`
   - Database connectivity: verify promoted replicas are writable
6. **Notify all stakeholders** — Communication Template B
7. **Monitor DR region** for 24 hours minimum
8. **Plan failback** once primary region is restored

**Estimated Recovery:** 15-30 minutes

**⚠️ IMPORTANT:** Failback to primary region requires a separate planned procedure. Do NOT fail back without:
- Primary region fully verified healthy
- Data reconciliation between regions
- Approved maintenance window

---

### Scenario 5: Data Corruption

**Severity:** High | **Priority:** P1 | **Auto-Recovery:** No

**Description:** Database data becomes corrupted due to software bug, operator error, or storage failure.

**Detection:**
- Application errors indicating data integrity issues
- Database constraint violations
- Checksum failures in telemetry pipeline
- User reports of incorrect patient data

**Decision Tree:**
```
Data corruption detected
    │
    ├── Scope assessment
    │   ├── Single record ──→ Manual correction + audit log
    │   ├── Single table ──→ Point-in-time restore (table-level)
    │   ├── Single database ──→ Full database restore
    │   └── Multiple databases ──→ Full cluster restore
    │
    ├── PHI data affected?
    │   └── Yes ──→ Trigger HIPAA Breach Assessment Protocol
    │
    └── Identify corruption timestamp
        └── Required for point-in-time recovery target
```

**Runbook:**
1. **STOP writes to affected database(s)** immediately:
   ```bash
   kubectl scale deployment <service> --replicas=0 -n neurosphere-production
   ```
2. **Assess corruption scope:**
   ```sql
   -- Check for constraint violations
   SELECT * FROM pg_stat_user_tables WHERE n_dead_tup > 1000;
   -- Run integrity checks
   SELECT pg_catalog.pg_table_is_visible(oid) FROM pg_class;
   ```
3. **Identify last known good state** — review application logs, audit trail
4. **Choose recovery method:**
   - **PITR (preferred):** Restore to timestamp just before corruption
   - **Full restore:** Use daily backup if PITR not possible
5. **Execute restore:**
   ```bash
   ./disaster-recovery/scripts/restore-cluster.sh \
     --backup-date <YYYY-MM-DD> \
     --environment production \
     --component database \
     --database <db-name>
   ```
6. **Validate restored data** — run application-level integrity checks
7. **Root cause analysis** — identify and fix the source of corruption
8. **If PHI affected:** Follow HIPAA breach notification procedures (Section 9)

**Estimated Recovery:** 30-120 minutes (depending on scope)

---

### Scenario 6: Security Breach

**Severity:** Critical | **Priority:** P0 | **Auto-Recovery:** No

**Description:** Unauthorized access detected — potential data exfiltration, compromised credentials, or malicious insider activity.

**Detection:**
- Vault audit log anomalies
- Unusual API access patterns
- AWS GuardDuty alerts
- IDS/IPS alerts
- Failed authentication spikes

**Runbook:**
1. **ISOLATE compromised systems** — do NOT shut down (preserve forensic evidence):
   ```bash
   # Apply network policy to isolate compromised pods
   kubectl apply -f security/network-policies/isolation-policy.yaml
   
   # Revoke compromised credentials
   vault token revoke <token>
   vault lease revoke -prefix secret/
   ```
2. **Preserve evidence:**
   ```bash
   # Snapshot affected pods
   kubectl logs <pod> -n neurosphere-production > /evidence/pod-logs-$(date +%s).log
   
   # Capture network state
   kubectl get networkpolicies -n neurosphere-production -o yaml > /evidence/netpol.yaml
   
   # Export Vault audit logs
   aws s3 cp s3://neurosphere-production-audit-logs/ /evidence/vault-audit/ --recursive
   ```
3. **Rotate ALL secrets:**
   ```bash
   # Rotate database credentials
   vault write -force database/rotate-root/robot-db
   vault write -force database/rotate-root/patient-db
   vault write -force database/rotate-root/telemetry-db
   
   # Rotate service tokens
   vault token revoke -mode=orphan -accessor <accessor>
   ```
4. **Assess data exposure:**
   - Which databases were accessed?
   - Was PHI data accessed or exfiltrated?
   - What was the attack timeline?
5. **If PHI compromised:** Initiate HIPAA breach notification (see Section 9)
6. **Restore from clean backup** (pre-breach):
   ```bash
   ./disaster-recovery/scripts/restore-cluster.sh \
     --backup-date <pre-breach-date> \
     --environment production \
     --component full
   ```
7. **Harden:** Apply security patches, update WAF rules, review IAM policies
8. **Post-incident review** within 48 hours

**Estimated Recovery:** 2-8 hours (depending on scope)

---

### Scenario 7: Ransomware Attack

**Severity:** Critical | **Priority:** P0 | **Auto-Recovery:** No

**Description:** Ransomware encrypts cluster data or locks out operators.

**Detection:**
- Sudden inability to read data from databases
- Encryption-related errors across multiple services
- Ransom note in system files
- Mass file modification alerts

**Key Principle:** NeuroSphere maintains **air-gapped backups** in a separate AWS account with no cross-account IAM roles. Ransomware cannot reach these backups.

**Runbook:**
1. **DISCONNECT everything** — prevent lateral spread:
   ```bash
   # Isolate the cluster at the network level
   aws ec2 modify-vpc-attribute --vpc-id <vpc-id> --no-enable-dns-support
   
   # Revoke all IAM sessions
   aws iam put-role-policy --role-name neurosphere-node-role \
     --policy-name emergency-deny-all \
     --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"*","Resource":"*"}]}'
   ```
2. **DO NOT PAY ransom** — this is organizational policy
3. **Notify:**
   - CISO and Security Team (immediately)
   - Legal counsel (within 1 hour)
   - Law enforcement (FBI IC3) if applicable
   - HIPAA breach notification team (if PHI affected)
4. **Assess scope:**
   - Which systems are encrypted/compromised?
   - Are air-gapped backups intact?
   - What is the attack vector?
5. **Build clean environment:**
   ```bash
   # Deploy fresh EKS cluster from IaC (Terraform)
   cd infrastructure/terraform/dr
   terraform init
   terraform plan -var="environment=production" -var="region=us-west-2"
   terraform apply
   ```
6. **Restore from air-gapped backups:**
   ```bash
   # Access air-gapped backup account
   aws sts assume-role --role-arn arn:aws:iam::AIRGAP_ACCOUNT:role/emergency-restore
   
   # Copy backups to clean environment
   aws s3 sync s3://neurosphere-airgap-backups/latest/ s3://neurosphere-production-dr-backups/
   
   # Execute full restore
   ./disaster-recovery/scripts/restore-cluster.sh \
     --backup-date <last-clean-date> \
     --environment production \
     --component full
   ```
7. **Forensic analysis** — engage third-party IR firm
8. **Harden before reconnecting** — patch all vulnerabilities, rotate all credentials

**Estimated Recovery:** 4-24 hours (clean rebuild)

---

## 6. Escalation Matrix

### 6.1 Escalation Paths

| Level | Role | Contact | Response Time | Triggers |
|-------|------|---------|---------------|----------|
| L1 | On-Call Engineer | PagerDuty rotation | < 5 min | Any alert fires |
| L2 | Engineering Lead | PagerDuty + phone | < 15 min | L1 cannot resolve in 15 min |
| L3 | VP Engineering | Phone + SMS | < 30 min | P0 incident, region failure |
| L4 | CISO | Phone + SMS | < 15 min | Security breach, data exposure |
| L5 | Chief Medical Officer | Phone | < 30 min | Patient safety impact |
| L6 | CEO / Board | Phone | < 1 hr | Major breach, regulatory action |

### 6.2 On-Call Rotation

| Week | Primary | Secondary | Escalation |
|------|---------|-----------|------------|
| Odd | Platform Team A | Platform Team B | Engineering Lead A |
| Even | Platform Team B | Platform Team A | Engineering Lead B |

---

## 7. Communication Templates

### Template A: Service Degradation (Internal)

```
Subject: [NEUROSPHERE-{P-LEVEL}] Service Degradation — {SERVICE_NAME}

Team,

We are experiencing degradation in {SERVICE_NAME}.

Impact: {DESCRIPTION_OF_IMPACT}
Start Time: {TIMESTAMP} UTC
Affected Users: {SCOPE}
Current Status: {INVESTIGATING / IDENTIFIED / MITIGATING / RESOLVED}

Actions Taken:
1. {ACTION_1}
2. {ACTION_2}

Next Update: {TIME} UTC (or sooner if status changes)

Incident Commander: {NAME}
```

### Template B: DR Failover Notification

```
Subject: 🚨 [CRITICAL] NeuroSphere DR Failover Activated — {ENVIRONMENT}

ALL ENGINEERING + CLINICAL OPERATIONS,

A disaster recovery failover has been executed for NeuroSphere {ENVIRONMENT}.

Primary Region:  {PRIMARY_REGION} (UNAVAILABLE)
DR Region:       {DR_REGION} (NOW ACTIVE)
Failover Time:   {TIMESTAMP} UTC
Triggered By:    {OPERATOR / AUTOMATED}

Impact:
- All services now running in DR region
- Database replicas promoted to primary
- DNS updated: api.neurosphere.io → {DR_REGION}

Immediate Actions Required:
1. Clinical teams: Verify patient monitoring systems
2. Engineering: Monitor DR region dashboards
3. All: Report any anomalies to #incident-response

Estimated Duration: Until primary region is restored and failback is executed.

Incident Commander: {NAME}
War Room: {LINK}
Status Page: {LINK}
```

### Template C: HIPAA Breach Notification

```
Subject: [CONFIDENTIAL] HIPAA Security Incident — Breach Assessment Required

HIPAA Privacy Officer, Legal, CISO,

A security incident has been detected that may involve Protected Health Information (PHI).

Incident ID: {ID}
Detection Time: {TIMESTAMP} UTC
Affected System: {SYSTEM}
Potential PHI Exposure: {DESCRIPTION}
Number of Records Potentially Affected: {COUNT}

Assessment Required Per 45 CFR §164.402:
- Was PHI acquired or accessed?
- Was PHI unsecured (unencrypted)?
- Who accessed the PHI?
- Was the PHI actually viewed or used?

Timeline:
- Risk assessment must be completed within 24 hours
- If breach confirmed: HHS notification within 60 days
- If >500 individuals: Media notification required

Incident Commander: {NAME}
```

---

## 8. DR Testing Schedule

### 8.1 Testing Calendar

| Frequency | Test Type | Scope | Duration | Participants |
|-----------|-----------|-------|----------|-------------|
| **Monthly** | Backup Verification | Restore 1 DB to isolated env | 2 hours | On-call engineer |
| **Quarterly** | Single-Service Restore | Full service restore drill | 4 hours | Platform team |
| **Semi-Annually** | Full DR Simulation | Complete failover to DR region (staging) | 8 hours | All engineering |
| **Annually** | Region Failover Test | Production failover to DR region | 12 hours | All engineering + clinical ops |

### 8.2 Monthly: Backup Verification

**Objective:** Confirm backups are valid and restorable.

**Procedure:**
1. Select one database at random
2. Download latest backup from S3
3. Verify GPG decryption succeeds
4. Restore to isolated RDS instance
5. Run data integrity queries
6. Document results in DR test log
7. Destroy isolated instance

**Success Criteria:**
- [ ] Backup downloads successfully
- [ ] Checksum matches
- [ ] GPG decryption succeeds
- [ ] Database restores without errors
- [ ] Sample queries return expected results
- [ ] Restore completes within RTO target

### 8.3 Quarterly: Single-Service Restore Drill

**Objective:** Validate end-to-end restore of a single service including database, configuration, and health verification.

**Procedure:**
1. Select target service (rotate through services each quarter)
2. Deploy isolated namespace: `neurosphere-dr-test`
3. Execute restore script with `--dry-run` first
4. Execute actual restore
5. Verify service health endpoint
6. Run integration test suite against restored service
7. Document timing, issues, and lessons learned
8. Cleanup test namespace

**Success Criteria:**
- [ ] Restore script executes without errors
- [ ] Service passes health checks
- [ ] Integration tests pass
- [ ] Restore time within RTO target
- [ ] No data integrity issues

### 8.4 Semi-Annual: Full DR Simulation

**Objective:** Simulate complete infrastructure failure and validate full recovery in DR region.

**Procedure:**
1. **Pre-test:** Brief all participants, confirm staging environment ready
2. **Simulate failure:** Disable primary region services in staging
3. **Execute failover:** Run `dr-failover.sh` against staging
4. **Validate:**
   - All services healthy in DR region
   - Database replicas promoted and writable
   - Vault operational in DR
   - DNS correctly resolved
5. **Measure:** Record actual RTO for each service
6. **Failback:** Execute planned failback to primary
7. **Post-test:** Retrospective, update runbooks with findings

**Success Criteria:**
- [ ] All P0 services recovered within RTO
- [ ] All P1 services recovered within RTO
- [ ] No data loss beyond RPO targets
- [ ] Failback successful
- [ ] Communication procedures followed

### 8.5 Annual: Production Region Failover Test

**Objective:** Validate production DR capabilities with real traffic.

**Procedure:**
1. **4 weeks before:** Announce maintenance window to all stakeholders
2. **1 week before:** Final readiness review, confirm rollback plan
3. **Day of:**
   - Shift production traffic to DR region via Route53
   - Monitor for 2 hours with live traffic
   - Execute failback to primary
   - Monitor for 2 hours post-failback
4. **Post-test:** Full retrospective, executive summary

**Scheduling Constraints:**
- Must occur during lowest-traffic period
- Must have clinical operations approval
- Must NOT coincide with any scheduled surgical procedures
- Requires 48-hour advance notice to all connected hospital systems

---

## 9. Compliance & Regulatory

### 9.1 HIPAA Requirements (45 CFR §164)

| Requirement | Implementation |
|-------------|----------------|
| §164.308(a)(7) — Contingency Plan | This DR plan |
| §164.308(a)(7)(ii)(A) — Data Backup Plan | Daily automated backups with encryption |
| §164.308(a)(7)(ii)(B) — DR Plan | Multi-region failover with tested runbooks |
| §164.308(a)(7)(ii)(C) — Emergency Mode | Failover script with automated DNS switch |
| §164.308(a)(7)(ii)(D) — Testing | Monthly/quarterly/semi-annual/annual schedule |
| §164.308(a)(7)(ii)(E) — Criticality Analysis | RTO/RPO targets per service priority |
| §164.312(a)(2)(ii) — Emergency Access | Break-glass procedures documented |
| §164.312(c)(1) — Integrity Controls | Checksums, encryption, audit logs |
| §164.312(e)(1) — Transmission Security | TLS 1.3, SSE-KMS, GPG encryption |

### 9.2 Breach Notification Timeline

```
Incident Detected ──→ Risk Assessment (24 hr) ──→ Breach Confirmed?
    │                                                   │
    │                                               Yes │
    │                                                   ▼
    │                                    ┌──────────────────────┐
    │                                    │ < 500 individuals    │
    │                                    │ Notify HHS: 60 days  │
    │                                    │ Notify individuals:  │
    │                                    │   60 days             │
    │                                    ├──────────────────────┤
    │                                    │ ≥ 500 individuals    │
    │                                    │ Notify HHS: 60 days  │
    │                                    │ Notify individuals:  │
    │                                    │   60 days             │
    │                                    │ Notify media: 60 days│
    │                                    └──────────────────────┘
    │
    └── No ──→ Document assessment, retain for 6 years
```

### 9.3 Audit Log Retention

| Log Type | Retention | Storage | Access |
|----------|-----------|---------|--------|
| Backup operation logs | 7 years | S3 Glacier | CISO + Compliance |
| Restore operation logs | 7 years | S3 Glacier | CISO + Compliance |
| Vault audit logs | 7 years | S3 Glacier | CISO + Compliance |
| DR test results | 7 years | S3 Standard | Engineering + Compliance |
| Incident reports | 7 years | Document management system | Legal + CISO |

---

## 10. Appendices

### Appendix A: Emergency Contact List

| Role | Name | Phone | Email | PagerDuty |
|------|------|-------|-------|-----------|
| VP Engineering | [REDACTED] | [REDACTED] | [REDACTED] | @vp-eng |
| CISO | [REDACTED] | [REDACTED] | [REDACTED] | @ciso |
| Chief Medical Officer | [REDACTED] | [REDACTED] | [REDACTED] | @cmo |
| Platform Lead | [REDACTED] | [REDACTED] | [REDACTED] | @platform-lead |
| HIPAA Privacy Officer | [REDACTED] | [REDACTED] | [REDACTED] | @privacy-officer |

### Appendix B: Key AWS Resources

| Resource | Primary (us-east-1) | DR (us-west-2) |
|----------|-------------------|-----------------|
| EKS Cluster | `neurosphere-production` | `neurosphere-production-dr` |
| S3 Backup Bucket | `neurosphere-production-dr-backups` | Cross-region replica |
| RDS patient-db | `neurosphere-production-patient-db` | `*-patient-db-replica` |
| RDS robot-db | `neurosphere-production-robot-db` | `*-robot-db-replica` |
| RDS telemetry-db | `neurosphere-production-telemetry-db` | `*-telemetry-db-replica` |
| Route53 Zone | `neurosphere.io` | Same (global) |
| KMS Key | `alias/neurosphere-production-dr` | Region-specific CMK |

### Appendix C: Recovery Command Quick Reference

```bash
# Full cluster restore
./disaster-recovery/scripts/restore-cluster.sh \
  --backup-date 2026-06-19 --environment production --component full

# Single database restore
./disaster-recovery/scripts/restore-cluster.sh \
  --backup-date 2026-06-19 --environment production \
  --component database --database patient-db

# DR failover
./disaster-recovery/scripts/dr-failover.sh --environment production

# Health check only (no failover)
./disaster-recovery/scripts/dr-failover.sh --environment production --check-only

# Dry-run restore (validation only)
./disaster-recovery/scripts/restore-cluster.sh \
  --backup-date 2026-06-19 --environment production \
  --component full --dry-run
```

### Appendix D: Document Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-01-15 | Platform Engineering | Initial DR plan |
| 1.1 | 2026-03-01 | SRE Team | Added ransomware scenario |
| 2.0 | 2026-06-20 | Platform Engineering | Full rewrite with automated scripts, HIPAA alignment, testing schedule |

---

*This document is reviewed quarterly. Next review: 2026-09-20.*  
*For questions, contact: platform-engineering@neurosphere.io*
