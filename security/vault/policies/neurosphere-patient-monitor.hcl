# =============================================================================
# NeuroSphere Vault Policy: Patient Monitor Service
# =============================================================================
# Service-specific policy for the Patient Monitor microservice, which handles
# real-time patient vital signs monitoring, clinical alerting, and PHI
# (Protected Health Information) processing during surgical procedures.
#
# HIPAA COMPLIANCE — STRICT ACCESS CONTROLS
# This service processes PHI including:
#   - Patient vital signs (HR, SpO2, BP, EtCO2, temperature)
#   - Patient demographics and medical record numbers
#   - Procedure-specific clinical data
#   - Anesthesia monitoring data
#
# HIPAA §164.312(a)(2)(iv): Encryption and Decryption — PHI at rest must be
# encrypted. This service accesses PHI encryption keys for data protection.
#
# HIPAA §164.312(a)(1): Access Control — This policy enforces the minimum
# necessary standard: the Patient Monitor can ONLY access secrets required
# for its function, with EXPLICIT DENY on unrelated service secrets.
# =============================================================================

# ---------------------------------------------------------------------------
# Patient Monitor Service Secrets
# ---------------------------------------------------------------------------
# Service-specific configuration: vital sign thresholds, alert escalation
# rules, clinical decision support parameters, HL7/FHIR integration config.
path "neurosphere/data/services/patient-monitor/*" {
  capabilities = ["read"]
}

# ---------------------------------------------------------------------------
# Patient Database Credentials
# ---------------------------------------------------------------------------
# PostgreSQL credentials for the neurosphere_patients database.
# Stores: patient demographics (PHI), vital sign time-series, clinical
# alerts, procedure records, consent documentation references.
#
# HIPAA §164.530(j): Documentation — Access to this database is logged
# and auditable. All queries are traced for compliance reporting.
path "neurosphere/data/database/patient-db" {
  capabilities = ["read"]
}

# ---------------------------------------------------------------------------
# HIPAA Signing Certificates
# ---------------------------------------------------------------------------
# Digital signing certificates for:
#   - PHI data integrity verification
#   - Clinical document signing (CDA/FHIR documents)
#   - Audit log tamper-evidence signatures
#   - Consent form digital signatures
path "neurosphere/data/certificates/hipaa-signing" {
  capabilities = ["read"]
}

# ---------------------------------------------------------------------------
# PHI Encryption Keys
# ---------------------------------------------------------------------------
# Encryption keys for PHI at-rest and in-transit protection.
# Used for: AES-256 encryption of patient records, field-level encryption
# of sensitive demographics, encryption of clinical images/videos.
#
# HIPAA §164.312(a)(2)(iv): Implement a mechanism to encrypt and decrypt PHI.
path "neurosphere/data/phi-encryption/*" {
  capabilities = ["read"]
}

# ---------------------------------------------------------------------------
# EXPLICIT DENY — Robot Command Service Secrets
# ---------------------------------------------------------------------------
# The Patient Monitor service must NOT access Robot Command secrets.
# This enforces segmentation between clinical monitoring and surgical
# robot control systems — a defense-in-depth measure to prevent
# cross-contamination of access in case of service compromise.
#
# IEC 62443: Network and system segmentation for medical device security.
path "neurosphere/data/services/robot-command/*" {
  capabilities = ["deny"]
}
