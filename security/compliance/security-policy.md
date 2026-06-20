# NeuroSphere Security Policy

## 1. Purpose & Scope

This security policy governs the NeuroSphere Medical Robotics Platform, covering all autonomous surgical systems, diagnostic engines, patient monitoring services, and supporting infrastructure. It applies to all engineering, operations, and clinical staff who interact with platform systems.

**Regulatory Frameworks**: HIPAA (45 CFR Part 160/164), IEC 62443 (Industrial Cybersecurity), FDA 21 CFR Part 11 (Electronic Records), IEC 62304 (Medical Device Software).

---

## 2. Roles & Responsibilities

| Role | Responsibilities |
|------|-----------------|
| **Security Officer** | Policy enforcement, incident response lead, compliance audits |
| **Platform Engineers** | Secure code development, vulnerability remediation, infrastructure hardening |
| **DevOps/SRE** | Access control management, secrets rotation, monitoring alert triage |
| **Clinical Staff** | Report security anomalies, follow access procedures, protect PHI |
| **Compliance Officer** | HIPAA/FDA audit coordination, policy review, regulatory reporting |

---

## 3. Access Management

### 3.1 Authentication
- All service-to-service authentication via HashiCorp Vault with Kubernetes auth backend
- Human access requires MFA (multi-factor authentication)
- SSH key-based access only — no password authentication
- Service accounts use short-lived tokens (7-day default, 32-day maximum TTL)

### 3.2 Authorization
- **Principle of Least Privilege**: Each service has a dedicated Vault policy scoped to only its required secrets
- **RBAC**: Kubernetes RBAC with namespace isolation (neurosphere-core, neurosphere-vault, neurosphere-monitor)
- **Network Policies**: Default-deny with explicit allowlists between namespaces
- **Break-glass procedures**: Emergency access requires 2-person authorization and is fully audited

### 3.3 Access Reviews
- Quarterly access reviews for all service accounts and human users
- Automated detection of unused credentials (>30 days inactive)
- Vault lease expiration enforces automatic secret rotation

---

## 4. Encryption Standards

### 4.1 Data at Rest
- EKS secrets encrypted with AWS KMS (AES-256-GCM)
- ECR images encrypted with AES-256
- S3 buckets: SSE-S3 or SSE-KMS
- Database volumes: LUKS/dm-crypt encryption
- PHI data: Additional field-level encryption via Vault Transit engine

### 4.2 Data in Transit
- All inter-service communication over TLS 1.2+ (TLS 1.3 preferred)
- Kubernetes network policies restrict unencrypted traffic
- External API access requires TLS with valid certificates (cert-manager + Let's Encrypt)
- VPN required for administrative access to production clusters

---

## 5. Vulnerability Management

### 5.1 Scanning Schedule
| Scan Type | Tool | Frequency | Threshold |
|-----------|------|-----------|-----------|
| Container images | Trivy | Every CI build + weekly | Block on CRITICAL |
| Python SAST | Bandit | Every CI build | Block on HIGH |
| Node.js dependencies | npm audit | Every CI build | Block on CRITICAL |
| OWASP dependencies | Dependency-Check | Weekly | Block on CVSS ≥ 7.0 |
| Infrastructure | tfsec | Every Terraform change | Block on HIGH |

### 5.2 Remediation SLAs
| Severity | Remediation Window | Escalation |
|----------|-------------------|------------|
| CRITICAL | 24 hours | Immediate page to Security Officer |
| HIGH | 7 days | Engineering lead notification |
| MEDIUM | 30 days | Sprint backlog |
| LOW | 90 days | Quarterly review |

---

## 6. Incident Response Procedure

### Phase 1: Detection & Triage (0-15 minutes)
- Automated alerts via Prometheus/Alertmanager trigger PagerDuty
- On-call engineer assesses severity and patient safety impact
- If patient safety is at risk: immediately engage clinical backup procedures

### Phase 2: Containment (15-60 minutes)
- Isolate affected services using network policy updates
- Revoke compromised credentials via Vault
- Enable enhanced logging on affected systems
- For surgical systems: initiate safe-mode transition (manual control fallback)

### Phase 3: Eradication (1-24 hours)
- Identify root cause through ELK log analysis
- Patch vulnerabilities or remove threat vectors
- Rebuild affected container images from verified sources

### Phase 4: Recovery (24-72 hours)
- Restore services from known-good state
- Verify integrity of patient data and surgical records
- Gradual traffic restoration with enhanced monitoring

### Phase 5: Post-Incident Review (within 5 business days)
- Conduct blameless post-mortem
- Document lessons learned and timeline
- Update runbooks and alert rules
- File regulatory notifications if PHI was exposed (HIPAA Breach Notification Rule, 60-day window)

---

## 7. Audit & Monitoring

- **Vault Audit Logs**: All secret access logged with requester identity, timestamp, and operation
- **VPC Flow Logs**: All network traffic captured and retained for 365 days
- **EKS Control Plane Logs**: API server, audit, authenticator logs to CloudWatch
- **Application Logs**: Structured JSON logs shipped to ELK stack via Filebeat
- **Prometheus Metrics**: Real-time performance and health metrics with 15-day retention
- **Compliance Dashboard**: Grafana dashboard tracking security KPIs

---

## 8. Change Management

- All infrastructure changes via Terraform (no manual modifications)
- All application changes via Jenkins CI/CD pipeline
- Production deployments require:
  - Passing all security scans (Trivy, Bandit, npm audit)
  - Code review approval
  - Quality gate (≥80% test coverage)
  - Manual approval from engineering lead
- ECR images use immutable tags — no overwriting deployed versions
- Rollback capability via `kubectl rollout undo` or Jenkinsfile.deploy

---

## 9. Business Continuity

- Multi-AZ deployment in production (3 availability zones)
- Pod Disruption Budgets ensure minimum service availability during maintenance
- Patient monitor service: minimum 2 pods always available
- Automated failover for database connections
- Disaster recovery procedures documented separately (Phase 7)

---

## 10. Policy Review

This policy is reviewed and updated:
- **Quarterly**: Routine review by Security Officer
- **After incidents**: Updated based on post-mortem findings
- **Regulatory changes**: Updated within 30 days of relevant regulatory updates

**Last Review**: Initial version
**Next Review**: Quarterly
**Approved By**: NeuroSphere Security Team
