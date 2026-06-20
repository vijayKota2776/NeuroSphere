# =============================================================================
# NeuroSphere Vault Policy: Microservices (Shared)
# =============================================================================
# Baseline read-only access for all NeuroSphere microservices.
# Each service authenticates via Kubernetes auth and receives this policy
# in addition to its service-specific policy.
#
# Principle of Least Privilege: Services can only READ secrets they need.
# Write access to secrets is restricted to administrators and CI/CD pipelines.
#
# HIPAA §164.312(a)(1): Access Control — Each service is granted the minimum
# necessary access to perform its designated function.
# =============================================================================

# ---------------------------------------------------------------------------
# Shared Database Credentials (read-only)
# ---------------------------------------------------------------------------
# Services may read database connection strings and credentials.
# Each service should only use the credentials for its own database;
# application-level enforcement is handled by service-specific policies.
path "neurosphere/data/database/*" {
  capabilities = ["read"]
}

# ---------------------------------------------------------------------------
# Shared API Keys (read-only)
# ---------------------------------------------------------------------------
# Common API keys for external integrations (e.g., diagnostic AI endpoints,
# notification webhooks). Service-specific API keys are scoped separately.
path "neurosphere/data/api-keys/*" {
  capabilities = ["read"]
}

# ---------------------------------------------------------------------------
# TLS Certificates (read-only)
# ---------------------------------------------------------------------------
# Shared TLS certificates for inter-service mTLS communication.
# Services retrieve their certificates at startup and on rotation events.
path "neurosphere/data/certificates/*" {
  capabilities = ["read"]
}

# ---------------------------------------------------------------------------
# Dynamic Per-Service Secret Access
# ---------------------------------------------------------------------------
# Leverages Vault's identity templating to scope each Kubernetes service
# account to its own secret subtree. The template resolves the authenticated
# service account name, granting read access only to secrets under that
# service's namespace.
#
# Example: service account "robot-command-svc" can read:
#   neurosphere/data/robot-command-svc/*
# but NOT:
#   neurosphere/data/patient-monitor-svc/*
path "neurosphere/data/{{identity.entity.aliases.auth_kubernetes_*.metadata.service_account_name}}/*" {
  capabilities = ["read"]
}

# ---------------------------------------------------------------------------
# Deny System Backend Access
# ---------------------------------------------------------------------------
# Microservices must NOT have access to Vault system operations.
# This explicitly denies seal/unseal, policy changes, audit config, etc.
path "sys/*" {
  capabilities = ["deny"]
}
