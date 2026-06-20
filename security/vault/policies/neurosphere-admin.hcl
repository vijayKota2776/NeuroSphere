# =============================================================================
# NeuroSphere Vault Policy: Administrator
# =============================================================================
# Grants full administrative access to the Vault cluster.
#
# ASSIGNMENT: This policy should ONLY be assigned to:
#   - Platform engineering leads
#   - Security operations personnel
#   - Break-glass emergency access accounts
#
# HIPAA §164.312(a)(1): Access Control — Implement technical policies and
# procedures for systems that maintain PHI to allow access only to authorized
# persons or software programs.
#
# All actions under this policy are audit-logged. Misuse of admin privileges
# will trigger security incident response procedures.
# =============================================================================

# Full control over system backend — seal/unseal, policy management,
# auth method configuration, audit device management, etc.
path "sys/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# Full control over authentication methods — enable/disable/configure
# auth backends (Kubernetes, AppRole, LDAP, OIDC, etc.)
path "auth/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# Full control over the default secret/ mount — legacy KV access
path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Full control over the NeuroSphere secrets engine — all service secrets,
# database credentials, API keys, certificates, and PHI encryption keys.
path "neurosphere/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
