#!/bin/bash
# =============================================================================
# NeuroSphere Medical Robotics — Vault Initialization Script
# =============================================================================
# This script initializes and configures HashiCorp Vault for the NeuroSphere
# platform. It performs the following operations:
#
#   1. Wait for Vault to be ready (health check loop)
#   2. Initialize Vault (5 key shares, 3 key threshold)
#   3. Save unseal keys and root token securely
#   4. Unseal Vault using 3 of 5 keys
#   5. Login with root token
#   6. Enable audit logging (HIPAA requirement)
#   7. Enable KV v2 secrets engine at neurosphere/
#   8. Apply all access control policies
#   9. Enable Kubernetes auth method
#  10. Configure Kubernetes auth backend
#  11. Create Kubernetes auth roles for each service
#  12. Seed initial secrets (placeholder values)
#  13. Print configuration summary
#
# HIPAA Compliance Notes:
#   - Audit logging is enabled immediately after initialization
#   - All secret access is policy-controlled with least-privilege
#   - Unseal keys must be distributed to separate custodians
#   - Root token must be revoked after initial setup in production
#
# Usage:
#   ./init-vault.sh
#
# Environment Variables:
#   VAULT_ADDR       — Vault server address (default: http://127.0.0.1:8200)
#   VAULT_INIT_DIR   — Directory to store init output (default: /vault/init)
#   VAULT_POLICY_DIR — Directory containing .hcl policy files
#   VAULT_SECRETS_FILE — Path to seed-secrets.json
#   K8S_HOST         — Kubernetes API server URL
#   VAULT_NAMESPACE  — Vault namespace (default: neurosphere-vault)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_INIT_DIR="${VAULT_INIT_DIR:-/vault/init}"
VAULT_POLICY_DIR="${VAULT_POLICY_DIR:-/vault/policies}"
VAULT_SECRETS_FILE="${VAULT_SECRETS_FILE:-/vault/secrets/seed-secrets.json}"
VAULT_AUDIT_PATH="${VAULT_AUDIT_PATH:-/vault/audit/audit.log}"
K8S_HOST="${K8S_HOST:-https://kubernetes.default.svc}"
K8S_CA_CERT="${K8S_CA_CERT:-/var/run/secrets/kubernetes.io/serviceaccount/ca.crt}"
K8S_TOKEN_REVIEWER_JWT="${K8S_TOKEN_REVIEWER_JWT:-}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-neurosphere-vault}"

KEY_SHARES=5
KEY_THRESHOLD=3
MAX_WAIT_SECONDS=120
HEALTH_CHECK_INTERVAL=5

export VAULT_ADDR

# ---------------------------------------------------------------------------
# Color Output
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info()    { echo -e "${GREEN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') — $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') — $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') — $*"; }
log_step()    { echo -e "${CYAN}[STEP]${NC}  $(date '+%Y-%m-%d %H:%M:%S') — $*"; }
log_section() { echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"; }

# =============================================================================
# STEP 1: Wait for Vault to Be Ready
# =============================================================================
wait_for_vault() {
    log_section "STEP 1: Waiting for Vault to be ready"
    local elapsed=0

    while [ $elapsed -lt $MAX_WAIT_SECONDS ]; do
        # Vault returns 501 when not initialized, 503 when sealed, 200 when ready
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" "${VAULT_ADDR}/v1/sys/health" 2>/dev/null || echo "000")

        if [ "$http_code" = "200" ]; then
            log_info "Vault is initialized and unsealed (HTTP $http_code)"
            return 0
        elif [ "$http_code" = "501" ]; then
            log_info "Vault is running but not initialized (HTTP $http_code) — proceeding"
            return 0
        elif [ "$http_code" = "503" ]; then
            log_info "Vault is initialized but sealed (HTTP $http_code) — proceeding"
            return 0
        else
            log_warn "Vault not ready (HTTP $http_code). Retrying in ${HEALTH_CHECK_INTERVAL}s... (${elapsed}s/${MAX_WAIT_SECONDS}s)"
            sleep "$HEALTH_CHECK_INTERVAL"
            elapsed=$((elapsed + HEALTH_CHECK_INTERVAL))
        fi
    done

    log_error "Vault did not become ready within ${MAX_WAIT_SECONDS} seconds"
    exit 1
}

# =============================================================================
# STEP 2: Initialize Vault
# =============================================================================
initialize_vault() {
    log_section "STEP 2: Initializing Vault"

    # Check if already initialized
    local init_status
    init_status=$(curl -s "${VAULT_ADDR}/v1/sys/init" | jq -r '.initialized')

    if [ "$init_status" = "true" ]; then
        log_info "Vault is already initialized — skipping initialization"
        return 0
    fi

    log_info "Initializing Vault with ${KEY_SHARES} key shares, ${KEY_THRESHOLD} key threshold"
    log_warn "SECURITY: In production, use PGP-encrypted key shares distributed to separate custodians"

    # Initialize and capture output
    local init_response
    init_response=$(curl -s -X PUT "${VAULT_ADDR}/v1/sys/init" \
        -H "Content-Type: application/json" \
        -d "{
            \"secret_shares\": ${KEY_SHARES},
            \"secret_threshold\": ${KEY_THRESHOLD}
        }")

    # Validate response
    if echo "$init_response" | jq -e '.keys' > /dev/null 2>&1; then
        log_info "Vault initialized successfully"
    else
        log_error "Vault initialization failed: $init_response"
        exit 1
    fi

    # ---------------------------------------------------------------------------
    # STEP 3: Save Init Output
    # ---------------------------------------------------------------------------
    log_section "STEP 3: Saving unseal keys and root token"

    mkdir -p "$VAULT_INIT_DIR"
    echo "$init_response" | jq '.' > "${VAULT_INIT_DIR}/vault-keys.json"
    chmod 600 "${VAULT_INIT_DIR}/vault-keys.json"

    log_info "Init output saved to ${VAULT_INIT_DIR}/vault-keys.json (mode 600)"
    log_warn "╔══════════════════════════════════════════════════════════════╗"
    log_warn "║  CRITICAL SECURITY ACTION REQUIRED                         ║"
    log_warn "║                                                            ║"
    log_warn "║  1. Distribute unseal keys to ${KEY_SHARES} separate custodians        ║"
    log_warn "║  2. Store keys in separate secure locations (HSM, safe)    ║"
    log_warn "║  3. Revoke the root token after initial setup              ║"
    log_warn "║  4. Delete ${VAULT_INIT_DIR}/vault-keys.json after distribution  ║"
    log_warn "║                                                            ║"
    log_warn "║  HIPAA §164.312(a)(2)(iii): Automatic logoff              ║"
    log_warn "║  HIPAA §164.312(d): Person or entity authentication       ║"
    log_warn "╚══════════════════════════════════════════════════════════════╝"
}

# =============================================================================
# STEP 4: Unseal Vault
# =============================================================================
unseal_vault() {
    log_section "STEP 4: Unsealing Vault"

    # Check if already unsealed
    local seal_status
    seal_status=$(curl -s "${VAULT_ADDR}/v1/sys/seal-status" | jq -r '.sealed')

    if [ "$seal_status" = "false" ]; then
        log_info "Vault is already unsealed — skipping"
        return 0
    fi

    if [ ! -f "${VAULT_INIT_DIR}/vault-keys.json" ]; then
        log_error "Cannot unseal: ${VAULT_INIT_DIR}/vault-keys.json not found"
        log_error "Provide unseal keys manually via: vault operator unseal <key>"
        exit 1
    fi

    log_info "Unsealing Vault with ${KEY_THRESHOLD} of ${KEY_SHARES} keys"

    for i in $(seq 0 $((KEY_THRESHOLD - 1))); do
        local key
        key=$(jq -r ".keys[$i]" "${VAULT_INIT_DIR}/vault-keys.json")
        local unseal_response
        unseal_response=$(curl -s -X PUT "${VAULT_ADDR}/v1/sys/unseal" \
            -H "Content-Type: application/json" \
            -d "{\"key\": \"${key}\"}")

        local sealed
        sealed=$(echo "$unseal_response" | jq -r '.sealed')
        local progress
        progress=$(echo "$unseal_response" | jq -r '.progress')
        local threshold
        threshold=$(echo "$unseal_response" | jq -r '.t')

        if [ "$sealed" = "false" ]; then
            log_info "Vault unsealed successfully (key $((i + 1))/${KEY_THRESHOLD})"
            return 0
        else
            log_info "Unseal progress: key $((i + 1))/${KEY_THRESHOLD} applied (progress: ${progress}/${threshold})"
        fi
    done

    # Verify unseal
    seal_status=$(curl -s "${VAULT_ADDR}/v1/sys/seal-status" | jq -r '.sealed')
    if [ "$seal_status" = "true" ]; then
        log_error "Vault is still sealed after applying ${KEY_THRESHOLD} keys"
        exit 1
    fi

    log_info "Vault unsealed and ready"
}

# =============================================================================
# STEP 5: Login with Root Token
# =============================================================================
login_with_root_token() {
    log_section "STEP 5: Authenticating with root token"

    if [ ! -f "${VAULT_INIT_DIR}/vault-keys.json" ]; then
        log_error "Cannot login: ${VAULT_INIT_DIR}/vault-keys.json not found"
        exit 1
    fi

    ROOT_TOKEN=$(jq -r '.root_token' "${VAULT_INIT_DIR}/vault-keys.json")
    export VAULT_TOKEN="$ROOT_TOKEN"

    # Verify authentication
    local token_lookup
    token_lookup=$(curl -s -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/auth/token/lookup-self")

    if echo "$token_lookup" | jq -e '.data.id' > /dev/null 2>&1; then
        log_info "Authenticated successfully with root token"
        local policies
        policies=$(echo "$token_lookup" | jq -r '.data.policies | join(", ")')
        log_info "Token policies: ${policies}"
    else
        log_error "Authentication failed"
        exit 1
    fi
}

# =============================================================================
# STEP 6: Enable Audit Logging
# =============================================================================
enable_audit_logging() {
    log_section "STEP 6: Enabling audit logging (HIPAA requirement)"

    # Check if audit device already enabled
    local audit_list
    audit_list=$(curl -s -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/sys/audit")

    if echo "$audit_list" | jq -e '.["file/"]' > /dev/null 2>&1; then
        log_info "File audit device already enabled — skipping"
        return 0
    fi

    # Create audit log directory
    mkdir -p "$(dirname "$VAULT_AUDIT_PATH")"

    # Enable file audit device
    local audit_response
    audit_response=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
        -H "X-Vault-Token: ${VAULT_TOKEN}" \
        -H "Content-Type: application/json" \
        "${VAULT_ADDR}/v1/sys/audit/file" \
        -d "{
            \"type\": \"file\",
            \"options\": {
                \"file_path\": \"${VAULT_AUDIT_PATH}\",
                \"log_raw\": false,
                \"hmac_accessor\": true,
                \"mode\": \"0600\",
                \"format\": \"json\"
            }
        }")

    if [ "$audit_response" = "204" ] || [ "$audit_response" = "200" ]; then
        log_info "File audit device enabled at ${VAULT_AUDIT_PATH}"
        log_info "Audit format: JSON with HMAC'd sensitive fields"
        log_info "HIPAA §164.312(b): Audit controls — all Vault operations are now logged"
    else
        log_warn "Audit device enablement returned HTTP $audit_response — verify manually"
    fi
}

# =============================================================================
# STEP 7: Enable KV v2 Secrets Engine
# =============================================================================
enable_secrets_engine() {
    log_section "STEP 7: Enabling KV v2 secrets engine at neurosphere/"

    # Check if already mounted
    local mounts
    mounts=$(curl -s -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/sys/mounts")

    if echo "$mounts" | jq -e '.["neurosphere/"]' > /dev/null 2>&1; then
        log_info "Secrets engine already mounted at neurosphere/ — skipping"
        return 0
    fi

    local mount_response
    mount_response=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        -H "X-Vault-Token: ${VAULT_TOKEN}" \
        -H "Content-Type: application/json" \
        "${VAULT_ADDR}/v1/sys/mounts/neurosphere" \
        -d '{
            "type": "kv",
            "options": {
                "version": "2"
            },
            "description": "NeuroSphere Medical Robotics — secrets store (HIPAA-compliant)",
            "config": {
                "max_lease_ttl": "768h",
                "default_lease_ttl": "168h"
            }
        }')

    if [ "$mount_response" = "204" ] || [ "$mount_response" = "200" ]; then
        log_info "KV v2 secrets engine mounted at neurosphere/"
        log_info "Version 2 enables secret versioning and soft-delete for compliance"
    else
        log_error "Failed to mount secrets engine (HTTP $mount_response)"
        exit 1
    fi
}

# =============================================================================
# STEP 8: Apply Access Control Policies
# =============================================================================
apply_policies() {
    log_section "STEP 8: Applying access control policies"

    local policies=(
        "neurosphere-admin"
        "neurosphere-services"
        "neurosphere-robot-command"
        "neurosphere-patient-monitor"
        "neurosphere-cicd"
    )

    for policy_name in "${policies[@]}"; do
        local policy_file="${VAULT_POLICY_DIR}/${policy_name}.hcl"

        if [ ! -f "$policy_file" ]; then
            log_warn "Policy file not found: ${policy_file} — skipping"
            continue
        fi

        # Read policy content and apply via API
        local policy_content
        policy_content=$(cat "$policy_file")

        local policy_response
        policy_response=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
            -H "X-Vault-Token: ${VAULT_TOKEN}" \
            -H "Content-Type: application/json" \
            "${VAULT_ADDR}/v1/sys/policies/acl/${policy_name}" \
            -d "$(jq -n --arg policy "$policy_content" '{"policy": $policy}')")

        if [ "$policy_response" = "204" ] || [ "$policy_response" = "200" ]; then
            log_info "Policy applied: ${policy_name}"
        else
            log_error "Failed to apply policy ${policy_name} (HTTP ${policy_response})"
        fi
    done
}

# =============================================================================
# STEP 9: Enable Kubernetes Auth Method
# =============================================================================
enable_kubernetes_auth() {
    log_section "STEP 9: Enabling Kubernetes auth method"

    # Check if already enabled
    local auth_list
    auth_list=$(curl -s -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/sys/auth")

    if echo "$auth_list" | jq -e '.["kubernetes/"]' > /dev/null 2>&1; then
        log_info "Kubernetes auth method already enabled — skipping"
        return 0
    fi

    local auth_response
    auth_response=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        -H "X-Vault-Token: ${VAULT_TOKEN}" \
        -H "Content-Type: application/json" \
        "${VAULT_ADDR}/v1/sys/auth/kubernetes" \
        -d '{
            "type": "kubernetes",
            "description": "Kubernetes auth for NeuroSphere service pods"
        }')

    if [ "$auth_response" = "204" ] || [ "$auth_response" = "200" ]; then
        log_info "Kubernetes auth method enabled"
    else
        log_error "Failed to enable Kubernetes auth (HTTP $auth_response)"
        exit 1
    fi
}

# =============================================================================
# STEP 10: Configure Kubernetes Auth Backend
# =============================================================================
configure_kubernetes_auth() {
    log_section "STEP 10: Configuring Kubernetes auth backend"

    # Read the service account JWT if not provided
    if [ -z "$K8S_TOKEN_REVIEWER_JWT" ] && [ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
        K8S_TOKEN_REVIEWER_JWT=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
    fi

    # Read the K8s CA cert
    local k8s_ca_cert=""
    if [ -f "$K8S_CA_CERT" ]; then
        k8s_ca_cert=$(cat "$K8S_CA_CERT")
    fi

    local config_payload
    config_payload=$(jq -n \
        --arg k8s_host "$K8S_HOST" \
        --arg token_reviewer_jwt "$K8S_TOKEN_REVIEWER_JWT" \
        --arg k8s_ca_cert "$k8s_ca_cert" \
        '{
            "kubernetes_host": $k8s_host,
            "token_reviewer_jwt": $token_reviewer_jwt,
            "kubernetes_ca_cert": $k8s_ca_cert,
            "issuer": "https://kubernetes.default.svc.cluster.local"
        }')

    local config_response
    config_response=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        -H "X-Vault-Token: ${VAULT_TOKEN}" \
        -H "Content-Type: application/json" \
        "${VAULT_ADDR}/v1/auth/kubernetes/config" \
        -d "$config_payload")

    if [ "$config_response" = "204" ] || [ "$config_response" = "200" ]; then
        log_info "Kubernetes auth configured — K8s host: ${K8S_HOST}"
    else
        log_warn "Kubernetes auth configuration returned HTTP $config_response"
        log_warn "This is expected if running outside of Kubernetes. Configure manually later."
    fi
}

# =============================================================================
# STEP 11: Create Kubernetes Auth Roles
# =============================================================================
create_kubernetes_roles() {
    log_section "STEP 11: Creating Kubernetes auth roles for services"

    # Role definitions: name, service_account, namespace, policies, ttl
    declare -A roles
    roles=(
        ["robot-command"]="robot-command-svc|${VAULT_NAMESPACE}|neurosphere-services,neurosphere-robot-command|1h"
        ["patient-monitor"]="patient-monitor-svc|${VAULT_NAMESPACE}|neurosphere-services,neurosphere-patient-monitor|1h"
        ["telemetry-collector"]="telemetry-collector-svc|${VAULT_NAMESPACE}|neurosphere-services|1h"
        ["diagnostic-ai"]="diagnostic-ai-svc|${VAULT_NAMESPACE}|neurosphere-services|1h"
        ["api-gateway"]="api-gateway-svc|${VAULT_NAMESPACE}|neurosphere-services|30m"
        ["cicd-pipeline"]="cicd-pipeline-svc|${VAULT_NAMESPACE}|neurosphere-cicd|30m"
    )

    for role_name in "${!roles[@]}"; do
        IFS='|' read -r svc_account namespace policies ttl <<< "${roles[$role_name]}"

        # Convert comma-separated policies to JSON array
        local policies_json
        policies_json=$(echo "$policies" | jq -R 'split(",")')

        local role_payload
        role_payload=$(jq -n \
            --arg sa "$svc_account" \
            --arg ns "$namespace" \
            --argjson policies "$policies_json" \
            --arg ttl "$ttl" \
            '{
                "bound_service_account_names": [$sa],
                "bound_service_account_namespaces": [$ns],
                "policies": $policies,
                "ttl": $ttl,
                "max_ttl": "4h"
            }')

        local role_response
        role_response=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
            -H "X-Vault-Token: ${VAULT_TOKEN}" \
            -H "Content-Type: application/json" \
            "${VAULT_ADDR}/v1/auth/kubernetes/role/${role_name}" \
            -d "$role_payload")

        if [ "$role_response" = "204" ] || [ "$role_response" = "200" ]; then
            log_info "Role created: ${role_name} (sa: ${svc_account}, ns: ${namespace}, ttl: ${ttl})"
        else
            log_warn "Role creation for ${role_name} returned HTTP $role_response"
        fi
    done
}

# =============================================================================
# STEP 12: Seed Initial Secrets
# =============================================================================
seed_secrets() {
    log_section "STEP 12: Seeding initial secrets"

    if [ ! -f "$VAULT_SECRETS_FILE" ]; then
        log_warn "Secrets file not found: ${VAULT_SECRETS_FILE} — skipping secret seeding"
        return 0
    fi

    log_info "Loading secrets from ${VAULT_SECRETS_FILE}"
    log_warn "These are PLACEHOLDER values — replace with real credentials before production use"

    # Helper function to write a secret to Vault KV v2
    write_secret() {
        local path="$1"
        local data="$2"

        local write_response
        write_response=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
            -H "X-Vault-Token: ${VAULT_TOKEN}" \
            -H "Content-Type: application/json" \
            "${VAULT_ADDR}/v1/neurosphere/data/${path}" \
            -d "{\"data\": ${data}}")

        if [ "$write_response" = "200" ] || [ "$write_response" = "204" ]; then
            log_info "  Secret written: neurosphere/${path}"
        else
            log_error "  Failed to write secret: neurosphere/${path} (HTTP ${write_response})"
        fi
    }

    # Seed database credentials
    log_info "Seeding database credentials..."
    for db in $(jq -r '.database | keys[]' "$VAULT_SECRETS_FILE"); do
        local db_data
        db_data=$(jq -c ".database[\"${db}\"]" "$VAULT_SECRETS_FILE")
        write_secret "database/${db}" "$db_data"
    done

    # Seed API keys
    log_info "Seeding API keys..."
    for key in $(jq -r '."api-keys" | keys[]' "$VAULT_SECRETS_FILE"); do
        local key_data
        key_data=$(jq -c ".\"api-keys\"[\"${key}\"]" "$VAULT_SECRETS_FILE")
        write_secret "api-keys/${key}" "$key_data"
    done

    # Seed CI/CD secrets
    log_info "Seeding CI/CD secrets..."
    for cicd_key in $(jq -r '.cicd | keys[]' "$VAULT_SECRETS_FILE"); do
        local cicd_data
        cicd_data=$(jq -c ".cicd[\"${cicd_key}\"]" "$VAULT_SECRETS_FILE")
        write_secret "cicd/${cicd_key}" "$cicd_data"
    done

    # Seed certificates (if present)
    if jq -e '.certificates' "$VAULT_SECRETS_FILE" > /dev/null 2>&1; then
        log_info "Seeding TLS certificates..."
        for cert in $(jq -r '.certificates | keys[]' "$VAULT_SECRETS_FILE"); do
            local cert_data
            cert_data=$(jq -c ".certificates[\"${cert}\"]" "$VAULT_SECRETS_FILE")
            write_secret "certificates/${cert}" "$cert_data"
        done
    fi

    # Seed PHI encryption keys (if present)
    if jq -e '."phi-encryption"' "$VAULT_SECRETS_FILE" > /dev/null 2>&1; then
        log_info "Seeding PHI encryption keys..."
        for phi_key in $(jq -r '."phi-encryption" | keys[]' "$VAULT_SECRETS_FILE"); do
            local phi_data
            phi_data=$(jq -c ".\"phi-encryption\"[\"${phi_key}\"]" "$VAULT_SECRETS_FILE")
            write_secret "phi-encryption/${phi_key}" "$phi_data"
        done
    fi
}

# =============================================================================
# STEP 13: Print Summary
# =============================================================================
print_summary() {
    log_section "INITIALIZATION COMPLETE — SUMMARY"

    echo -e ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║          NeuroSphere Vault Initialization Complete          ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║                                                            ║${NC}"
    echo -e "${GREEN}║  Vault Address:    ${VAULT_ADDR}              ║${NC}"
    echo -e "${GREEN}║  Cluster Name:     neurosphere-vault                        ║${NC}"
    echo -e "${GREEN}║  Secrets Engine:   neurosphere/ (KV v2)                     ║${NC}"
    echo -e "${GREEN}║  Auth Method:      Kubernetes                               ║${NC}"
    echo -e "${GREEN}║  Audit Backend:    File (${VAULT_AUDIT_PATH})    ║${NC}"
    echo -e "${GREEN}║                                                            ║${NC}"
    echo -e "${GREEN}║  Policies Applied:                                          ║${NC}"
    echo -e "${GREEN}║    • neurosphere-admin          (full admin)                ║${NC}"
    echo -e "${GREEN}║    • neurosphere-services       (shared service read)       ║${NC}"
    echo -e "${GREEN}║    • neurosphere-robot-command   (robot control)            ║${NC}"
    echo -e "${GREEN}║    • neurosphere-patient-monitor (PHI handling)             ║${NC}"
    echo -e "${GREEN}║    • neurosphere-cicd            (CI/CD pipeline)           ║${NC}"
    echo -e "${GREEN}║                                                            ║${NC}"
    echo -e "${GREEN}║  K8s Auth Roles:                                            ║${NC}"
    echo -e "${GREEN}║    • robot-command        → robot-command-svc              ║${NC}"
    echo -e "${GREEN}║    • patient-monitor      → patient-monitor-svc            ║${NC}"
    echo -e "${GREEN}║    • telemetry-collector  → telemetry-collector-svc        ║${NC}"
    echo -e "${GREEN}║    • diagnostic-ai        → diagnostic-ai-svc             ║${NC}"
    echo -e "${GREEN}║    • api-gateway          → api-gateway-svc               ║${NC}"
    echo -e "${GREEN}║    • cicd-pipeline        → cicd-pipeline-svc             ║${NC}"
    echo -e "${GREEN}║                                                            ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║  POST-INIT ACTIONS REQUIRED:                               ║${NC}"
    echo -e "${YELLOW}║                                                            ║${NC}"
    echo -e "${YELLOW}║  1. Distribute unseal keys to separate custodians          ║${NC}"
    echo -e "${YELLOW}║  2. Replace all CHANGE_ME values with real credentials     ║${NC}"
    echo -e "${YELLOW}║  3. Revoke the root token:                                 ║${NC}"
    echo -e "${YELLOW}║     vault token revoke <root-token>                        ║${NC}"
    echo -e "${YELLOW}║  4. Delete ${VAULT_INIT_DIR}/vault-keys.json               ║${NC}"
    echo -e "${YELLOW}║  5. Enable TLS with production certificates                ║${NC}"
    echo -e "${YELLOW}║  6. Configure backup/snapshot schedule                     ║${NC}"
    echo -e "${YELLOW}║  7. Set up monitoring alerts for seal status               ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo -e ""
}

# =============================================================================
# Main Execution
# =============================================================================
main() {
    echo -e "${BLUE}"
    echo "  _   _                      ____        _                   "
    echo " | \\ | | ___ _   _ _ __ ___/ ___| _ __ | |__   ___ _ __ ___ "
    echo " |  \\| |/ _ \\ | | | '__/ _ \\___ \\| '_ \\| '_ \\ / _ \\ '__/ _ \\"
    echo " | |\\  |  __/ |_| | | | (_) |__) | |_) | | | |  __/ | |  __/"
    echo " |_| \\_|\\___|\\__,_|_|  \\___/____/| .__/|_| |_|\\___|_|  \\___|"
    echo "                                 |_|                         "
    echo "  Vault Initialization Script — Medical Robotics Platform    "
    echo -e "${NC}"

    wait_for_vault
    initialize_vault
    unseal_vault
    login_with_root_token
    enable_audit_logging
    enable_secrets_engine
    apply_policies
    enable_kubernetes_auth
    configure_kubernetes_auth
    create_kubernetes_roles
    seed_secrets
    print_summary
}

main "$@"
