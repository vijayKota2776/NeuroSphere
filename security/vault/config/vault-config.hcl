# =============================================================================
# NeuroSphere Medical Robotics — HashiCorp Vault Server Configuration
# =============================================================================
# This configuration is designed for healthcare environments requiring
# HIPAA compliance, PHI protection, and audit-grade secret management.
#
# Environment: Development / Staging
# For production, enable TLS and switch to Consul/Raft storage backend.
# =============================================================================

ui = true
cluster_name = "neurosphere-vault"

# -----------------------------------------------------------------------------
# Storage Backend
# -----------------------------------------------------------------------------
# File storage backend for development and testing environments.
# PRODUCTION NOTE: Replace with Consul, Raft (integrated storage), or
# cloud-managed backends (AWS DynamoDB, GCP Cloud Spanner) for HA.
# -----------------------------------------------------------------------------
storage "file" {
  path = "/vault/data"
}

# -----------------------------------------------------------------------------
# TCP Listener
# -----------------------------------------------------------------------------
# HIPAA §164.312(e)(1): Transmission Security — Implement technical security
# measures to guard against unauthorized access to PHI transmitted over
# electronic communications networks.
#
# PRODUCTION: Enable TLS with healthcare-grade certificates (minimum TLS 1.2).
# Uncomment tls_cert_file and tls_key_file, set tls_disable = 0.
# -----------------------------------------------------------------------------
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1  # Set to 0 and configure TLS certs in production

  # tls_cert_file = "/vault/tls/vault-cert.pem"
  # tls_key_file  = "/vault/tls/vault-key.pem"
  # tls_min_version = "tls12"
}

# -----------------------------------------------------------------------------
# Telemetry — Prometheus Integration
# -----------------------------------------------------------------------------
# Exposes metrics at /v1/sys/metrics?format=prometheus for monitoring
# Vault health, seal status, request latency, and token usage.
# Critical for healthcare SLA compliance and operational visibility.
# -----------------------------------------------------------------------------
telemetry {
  prometheus_retention_time = "30s"
  disable_hostname         = true
}

# -----------------------------------------------------------------------------
# API and Cluster Addresses
# -----------------------------------------------------------------------------
api_addr     = "http://0.0.0.0:8200"
cluster_addr = "https://0.0.0.0:8201"

# -----------------------------------------------------------------------------
# Lease TTL Configuration
# -----------------------------------------------------------------------------
# max_lease_ttl:     32 days — upper bound for any secret lease or token TTL.
# default_lease_ttl: 7 days  — default unless overridden per mount/role.
#
# Healthcare compliance note: Short-lived leases reduce the blast radius of
# compromised credentials. Services should renew leases proactively.
# -----------------------------------------------------------------------------
max_lease_ttl     = "768h"   # 32 days maximum
default_lease_ttl = "168h"   # 7 days default

# -----------------------------------------------------------------------------
# Audit Logging — HIPAA §164.312(b): Audit Controls
# -----------------------------------------------------------------------------
# HIPAA requires audit controls to record and examine activity in systems
# containing or accessing PHI. Enable audit logging IMMEDIATELY after
# Vault initialization:
#
#   vault audit enable file file_path=/vault/audit/audit.log
#
# Audit logs capture every Vault request/response (with sensitive fields
# HMAC'd). These logs must be retained per organizational retention policy
# (minimum 6 years for HIPAA).
#
# For production, enable multiple audit backends for redundancy:
#   vault audit enable -path=file file file_path=/vault/audit/audit.log
#   vault audit enable -path=syslog syslog tag="vault" facility="AUTH"
# -----------------------------------------------------------------------------
