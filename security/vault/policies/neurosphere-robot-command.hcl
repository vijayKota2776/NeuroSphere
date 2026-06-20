# =============================================================================
# NeuroSphere Vault Policy: Robot Command Service
# =============================================================================
# Service-specific policy for the Robot Command microservice, which manages
# real-time surgical robot control, kinematics computation, and haptic
# feedback processing.
#
# This service requires access to:
#   - Its own service secrets (configuration, feature flags)
#   - Robot database credentials (PostgreSQL — joint states, trajectories)
#   - Robot TLS certificates (mTLS to robot hardware controllers)
#   - Surgical controller API keys (real-time control plane auth)
#
# SAFETY NOTE: The Robot Command service is a safety-critical component.
# Secret access failures must trigger a safe-stop procedure on all connected
# surgical robots. Vault lease renewals must be monitored with alerting.
#
# IEC 62304 / IEC 80601-2-77: Medical device software lifecycle compliance
# requires documented access control for safety-critical subsystems.
# =============================================================================

# ---------------------------------------------------------------------------
# Robot Command Service Secrets
# ---------------------------------------------------------------------------
# Service-specific configuration: control loop parameters, safety thresholds,
# robot hardware endpoint URLs, haptic feedback calibration data.
path "neurosphere/data/services/robot-command/*" {
  capabilities = ["read"]
}

# ---------------------------------------------------------------------------
# Robot Database Credentials
# ---------------------------------------------------------------------------
# PostgreSQL credentials for the neurosphere_robots database.
# Stores: robot registry, joint calibration data, procedure trajectories,
# maintenance logs, safety interlock states.
path "neurosphere/data/database/robot-db" {
  capabilities = ["read"]
}

# ---------------------------------------------------------------------------
# Robot TLS Certificates
# ---------------------------------------------------------------------------
# mTLS certificates for secure communication with robot hardware controllers.
# Used for: real-time control commands, telemetry ingestion, firmware updates.
# Certificate rotation is coordinated with robot maintenance windows.
path "neurosphere/data/certificates/robot-tls" {
  capabilities = ["read"]
}

# ---------------------------------------------------------------------------
# Surgical Controller API Key
# ---------------------------------------------------------------------------
# Authentication credentials for the surgical control plane API.
# Used for: procedure authorization, instrument registration, safety checks.
path "neurosphere/data/api-keys/surgical-controller" {
  capabilities = ["read"]
}
