# NeuroSphere Medical Robotics — HIPAA Technical Safeguards Compliance Checklist

> **Document Classification:** CONFIDENTIAL — Internal Use Only  
> **Standard:** HIPAA Security Rule — 45 CFR Part 164, Subpart C  
> **Scope:** All NeuroSphere microservices processing or transmitting ePHI  
> **Last Reviewed:** 2026-06-15  
> **Next Review:** 2026-09-15  
> **Owner:** Security Engineering — NeuroSphere Platform Team  

---

## Compliance Status Legend

| Symbol | Meaning |
|--------|---------|
| ✅ | Fully Implemented — Evidence available |
| 🟡 | Partially Implemented — Remediation in progress |
| ❌ | Not Implemented — Risk accepted or planned |
| 🔄 | Under Review — Assessment in progress |

---

## §164.312(a)(1) — Access Control

**Requirement:** Implement technical policies and procedures for electronic information systems that maintain ePHI to allow access only to those persons or software programs that have been granted access rights.

### §164.312(a)(2)(i) — Unique User Identification ✅

| Attribute | Detail |
|-----------|--------|
| **Requirement** | Assign a unique name and/or number for identifying and tracking user identity |
| **Implementation** | Every human operator and service identity is assigned a unique identifier through HashiCorp Vault identity engine. Kubernetes service accounts provide unique identity per microservice pod. |
| **Technical Controls** | • Vault OIDC integration with corporate IdP (Azure AD) for human users<br>• Kubernetes ServiceAccount per deployment with bound token projection<br>• Vault AppRole with unique `role_id` + `secret_id` per service<br>• Audit logs include `accessor` and `entity_id` for attribution |
| **Evidence Location** | `infrastructure/vault/policies/` — RBAC policy definitions<br>`infrastructure/k8s/*/serviceaccount.yaml` — K8s identity configs<br>Vault audit log: `vault audit list -format=json` |
| **Status** | ✅ Fully Implemented |

### §164.312(a)(2)(ii) — Emergency Access Procedure ✅

| Attribute | Detail |
|-----------|--------|
| **Requirement** | Establish procedures for obtaining necessary ePHI during an emergency |
| **Implementation** | Break-glass procedure using Vault emergency tokens stored in hardware security modules (HSM) with dual-custody unsealing. Emergency access grants time-limited (1 hour) read-only access to critical patient telemetry systems. |
| **Technical Controls** | • Vault emergency policy: `emergency-break-glass` with TTL=1h<br>• Dual-custody unseal keys (Shamir's Secret Sharing, 3-of-5)<br>• Automated PagerDuty incident creation on emergency token use<br>• All emergency access logged to immutable audit trail (S3 + WORM) |
| **Evidence Location** | `infrastructure/vault/policies/emergency-break-glass.hcl`<br>`security/runbooks/emergency-access-procedure.md` |
| **Status** | ✅ Fully Implemented |

### §164.312(a)(2)(iii) — Automatic Logoff ✅

| Attribute | Detail |
|-----------|--------|
| **Requirement** | Implement electronic procedures that terminate a session after a predetermined time of inactivity |
| **Implementation** | All API tokens and Vault leases have enforced TTLs. Operator dashboard sessions timeout after 15 minutes of inactivity. Service-to-service tokens rotate every 24 hours with max TTL of 72 hours. |
| **Technical Controls** | • Vault token `default_lease_ttl=24h`, `max_lease_ttl=72h`<br>• Dashboard session timeout: 15 minutes (configurable via Helm)<br>• Kubernetes token audience-bound with 1h expiry<br>• Istio mTLS certificates rotate every 12 hours |
| **Evidence Location** | `infrastructure/vault/config/vault-config.hcl` — TTL settings<br>`services/operator-dashboard/src/config.js` — session config |
| **Status** | ✅ Fully Implemented |

### §164.312(a)(2)(iv) — Encryption and Decryption ✅

| Attribute | Detail |
|-----------|--------|
| **Requirement** | Implement a mechanism to encrypt and decrypt ePHI |
| **Implementation** | All ePHI is encrypted at rest using AWS KMS (AES-256-GCM) managed through Vault Transit secrets engine. Application-layer encryption wraps sensitive telemetry fields before storage. |
| **Technical Controls** | • Vault Transit engine: `neurosphere-phi-key` (AES-256-GCM, auto-rotate 90d)<br>• AWS KMS: EBS volume encryption (aws/ebs CMK)<br>• RDS: TDE with customer-managed CMK<br>• S3: SSE-KMS with bucket policy enforcing encryption<br>• Application-layer field-level encryption via `neurosphere.common.crypto` |
| **Evidence Location** | `infrastructure/vault/transit/` — Transit key configuration<br>`infrastructure/terraform/modules/kms/` — KMS key definitions<br>`services/common/crypto.py` — Field-level encryption library |
| **Status** | ✅ Fully Implemented |

---

## §164.312(b) — Audit Controls ✅

**Requirement:** Implement hardware, software, and/or procedural mechanisms that record and examine activity in information systems that contain or use ePHI.

| Attribute | Detail |
|-----------|--------|
| **Requirement** | Record and examine activity in systems containing ePHI |
| **Implementation** | Multi-layer audit logging captures all access to ePHI across infrastructure, application, and data layers. Logs are centralized in an ELK stack with 7-year retention and WORM (Write Once Read Many) archival. |
| **Technical Controls** | • **VPC Flow Logs:** All network traffic logged to CloudWatch + S3<br>• **Vault Audit Device:** File + syslog backends, logs every Vault operation<br>• **Kubernetes Audit:** API server audit policy logs all `create`, `update`, `delete`, `patch` operations on sensitive resources<br>• **Application Audit:** Structured JSON audit events via `neurosphere.common.audit` library<br>• **ELK Stack:** Elasticsearch (7-year retention) + Kibana dashboards<br>• **CloudTrail:** AWS API activity logged with log file validation<br>• **Prometheus:** Metrics on access patterns and anomaly detection |
| **Evidence Location** | `infrastructure/terraform/modules/vpc/flow-logs.tf`<br>`infrastructure/vault/audit/audit-config.hcl`<br>`infrastructure/k8s/audit-policy.yaml`<br>`infrastructure/elk/` — ELK stack configuration<br>`services/common/audit.py` — Application audit library |
| **Status** | ✅ Fully Implemented |

### Audit Log Retention Schedule

| Log Source | Retention | Archive | Integrity Check |
|-----------|-----------|---------|-----------------|
| Vault Audit | 7 years | S3 Glacier (WORM) | SHA-256 hash chain |
| VPC Flow Logs | 3 years | S3 Glacier | CloudWatch digest |
| K8s Audit | 2 years | S3 Standard-IA | Log file validation |
| Application Audit | 7 years | S3 Glacier (WORM) | Merkle tree |
| CloudTrail | 7 years | S3 Glacier (WORM) | AWS digest files |

---

## §164.312(c)(1) — Integrity ✅

**Requirement:** Implement policies and procedures to protect ePHI from improper alteration or destruction.

| Attribute | Detail |
|-----------|--------|
| **Requirement** | Protect ePHI from improper alteration or destruction |
| **Implementation** | Defense-in-depth integrity controls span container images, runtime workloads, data storage, and network transmission. |
| **Technical Controls** | • **ECR Immutable Tags:** Container images use immutable tags; overwrite prohibited<br>• **Image Signing:** Cosign/Sigstore signatures validated by Kyverno admission controller<br>• **Database Checksums:** PostgreSQL `data_checksums=on` for page-level integrity<br>• **Object Versioning:** S3 bucket versioning enabled with MFA Delete<br>• **Vault Seal:** Auto-unseal via AWS KMS; tamper detection on seal status<br>• **Runtime Integrity:** Falco monitors file integrity on sensitive paths (`/etc/`, `/var/lib/vault/`)<br>• **Git Commit Signing:** All commits to `main` require GPG signatures |
| **Evidence Location** | `infrastructure/terraform/modules/ecr/` — ECR configuration<br>`infrastructure/k8s/kyverno/image-verify-policy.yaml`<br>`infrastructure/terraform/modules/rds/` — Database config<br>`security/policies/rego/image-signing.rego` |
| **Status** | ✅ Fully Implemented |

### §164.312(c)(2) — Mechanism to Authenticate ePHI ✅

| Attribute | Detail |
|-----------|--------|
| **Requirement** | Implement electronic mechanisms to corroborate that ePHI has not been altered or destroyed in an unauthorized manner |
| **Implementation** | HMAC-SHA256 integrity tags on all ePHI records at application layer. Database row-level checksums. API response integrity headers. |
| **Technical Controls** | • `X-NeuroSphere-Integrity` header on API responses (HMAC-SHA256)<br>• Vault Transit `hmac` operation for ePHI record signing<br>• Periodic integrity audit job compares stored HMACs (weekly cron) |
| **Evidence Location** | `services/common/integrity.py` — HMAC computation library<br>`infrastructure/k8s/cronjobs/integrity-audit.yaml` |
| **Status** | ✅ Fully Implemented |

---

## §164.312(d) — Person or Entity Authentication ✅

**Requirement:** Implement procedures to verify that a person or entity seeking access to ePHI is the one claimed.

| Attribute | Detail |
|-----------|--------|
| **Requirement** | Verify identity of persons/entities accessing ePHI |
| **Implementation** | Multi-factor authentication for human operators. mTLS with X.509 certificates for service-to-service authentication. Vault identity federation for centralized identity management. |
| **Technical Controls** | • **Human Users:** OIDC + MFA via Azure AD → Vault OIDC auth method<br>• **Service Accounts:** Kubernetes ServiceAccount token projection with audience binding<br>• **Service Mesh:** Istio mTLS with SPIFFE identity (X.509 SVIDs)<br>• **Vault Auth Methods:**<br>&nbsp;&nbsp;- `kubernetes` — Pod identity verification via TokenReview API<br>&nbsp;&nbsp;- `approle` — Machine identity with rate-limited `secret_id`<br>&nbsp;&nbsp;- `oidc` — Human operator authentication with MFA<br>• **API Gateway:** JWT validation with `iss`, `aud`, `exp` claims checked |
| **Evidence Location** | `infrastructure/vault/auth/` — Auth method configurations<br>`infrastructure/istio/` — mTLS and authorization policies<br>`infrastructure/k8s/*/serviceaccount.yaml` |
| **Status** | ✅ Fully Implemented |

---

## §164.312(e)(1) — Transmission Security ✅

**Requirement:** Implement technical security measures to guard against unauthorized access to ePHI that is being transmitted over an electronic communications network.

### §164.312(e)(2)(i) — Integrity Controls ✅

| Attribute | Detail |
|-----------|--------|
| **Requirement** | Implement security measures to ensure electronically transmitted ePHI is not improperly modified without detection |
| **Implementation** | TLS 1.3 enforced on all external and internal communications. Istio mTLS for service mesh. HMAC integrity verification on message payloads. |
| **Technical Controls** | • **External TLS:** AWS ALB with TLS 1.3, HSTS enabled<br>• **Internal mTLS:** Istio PeerAuthentication `STRICT` mode<br>• **gRPC:** TLS with channel credentials, protobuf CRC32 integrity<br>• **Message Queue:** NATS with TLS, signed JWTs for authorization<br>• **Cipher Suites:** TLS_AES_256_GCM_SHA384, TLS_CHACHA20_POLY1305_SHA256 |
| **Evidence Location** | `infrastructure/terraform/modules/alb/` — TLS configuration<br>`infrastructure/istio/peer-authentication.yaml`<br>`infrastructure/nats/nats-config.yaml` |
| **Status** | ✅ Fully Implemented |

### §164.312(e)(2)(ii) — Encryption ✅

| Attribute | Detail |
|-----------|--------|
| **Requirement** | Implement a mechanism to encrypt ePHI whenever deemed appropriate |
| **Implementation** | All network transmission of ePHI is encrypted. No plaintext ePHI traverses any network segment. |
| **Technical Controls** | • TLS 1.3 for all HTTP/gRPC traffic (external and internal)<br>• Istio mTLS `STRICT` — plaintext connections rejected<br>• NetworkPolicy denies all traffic not matching allowlist<br>• VPN (WireGuard) for administrative access to control plane<br>• DNS-over-TLS for service discovery |
| **Evidence Location** | `infrastructure/istio/` — mTLS policies<br>`infrastructure/k8s/network-policies/` — Network isolation<br>`infrastructure/terraform/modules/vpn/` — VPN configuration |
| **Status** | ✅ Fully Implemented |

---

## Compliance Summary

| HIPAA Section | Requirement | Status | Last Verified |
|--------------|-------------|--------|---------------|
| §164.312(a)(1) | Access Control | ✅ | 2026-06-15 |
| §164.312(a)(2)(i) | Unique User Identification | ✅ | 2026-06-15 |
| §164.312(a)(2)(ii) | Emergency Access Procedure | ✅ | 2026-06-15 |
| §164.312(a)(2)(iii) | Automatic Logoff | ✅ | 2026-06-15 |
| §164.312(a)(2)(iv) | Encryption and Decryption | ✅ | 2026-06-15 |
| §164.312(b) | Audit Controls | ✅ | 2026-06-15 |
| §164.312(c)(1) | Integrity | ✅ | 2026-06-15 |
| §164.312(c)(2) | Authentication of ePHI | ✅ | 2026-06-15 |
| §164.312(d) | Person/Entity Authentication | ✅ | 2026-06-15 |
| §164.312(e)(1) | Transmission Security | ✅ | 2026-06-15 |
| §164.312(e)(2)(i) | Integrity Controls | ✅ | 2026-06-15 |
| §164.312(e)(2)(ii) | Encryption | ✅ | 2026-06-15 |

---

## Appendix A: Risk Register Cross-Reference

| Risk ID | HIPAA Section | Risk Description | Mitigation | Residual Risk |
|---------|--------------|-------------------|------------|---------------|
| RISK-001 | §164.312(a)(1) | Compromised service account credentials | Vault short-lived tokens (24h TTL), automatic rotation | Low |
| RISK-002 | §164.312(b) | Audit log tampering | WORM storage, hash chain verification, separate audit account | Low |
| RISK-003 | §164.312(c)(1) | Container image supply chain attack | Sigstore signing, Kyverno admission, ECR immutable tags | Low |
| RISK-004 | §164.312(e)(1) | TLS downgrade attack | TLS 1.3 minimum, HSTS, Istio STRICT mTLS | Very Low |

---

## Appendix B: Evidence Artifact Index

| Evidence ID | Description | Location | Format |
|------------|-------------|----------|--------|
| EVD-001 | Vault RBAC policy definitions | `infrastructure/vault/policies/` | HCL |
| EVD-002 | Network policy manifests | `infrastructure/k8s/network-policies/` | YAML |
| EVD-003 | Penetration test report Q1-2026 | SharePoint: Security/PenTest/ | PDF |
| EVD-004 | Vulnerability scan reports | `security/reports/` | JSON/HTML |
| EVD-005 | Access review audit Q2-2026 | SharePoint: Security/AccessReview/ | XLSX |
| EVD-006 | Encryption key inventory | `infrastructure/vault/transit/` | HCL |
| EVD-007 | Incident response drill logs | SharePoint: Security/IR-Drills/ | PDF |

---

*This document is maintained by the NeuroSphere Security Engineering team and is subject to quarterly review. For questions, contact security@neurosphere.health.*
