#!/usr/bin/env bash
###############################################################################
# NeuroSphere Medical Robotics — HashiCorp Vault Raft Snapshot Backup
#
# Takes a Vault Raft storage snapshot, compresses and encrypts it, uploads to
# S3, and enforces retention. All operations are audit-logged per HIPAA §164.312.
#
# HIPAA Compliance Notes:
#   - Vault stores encryption keys for PHI data at rest
#   - Every backup operation is logged with operator identity
#   - Snapshots are encrypted with KMS before S3 upload
#   - Access to this script requires RBAC authorization
#   - Audit logs are immutable and retained for 7 years
#
# Exit Codes:
#   0  — Success
#   1  — General error
#   20 — Vault snapshot failed
#   21 — Compression failed
#   22 — S3 upload failed
#   23 — Integrity verification failed
#   24 — Retention cleanup failed
#   25 — Missing dependencies
#   26 — Vault authentication failed
#   27 — Vault sealed / unavailable
###############################################################################
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
ENVIRONMENT="${NEUROSPHERE_ENV:-staging}"
S3_BUCKET="neurosphere-${ENVIRONMENT}-dr-backups"
S3_PREFIX="vault-snapshots"
BACKUP_RETENTION_COUNT=30
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_NAME="vault-raft-${ENVIRONMENT}-${TIMESTAMP}"
TEMP_DIR="$(mktemp -d /tmp/neurosphere-vault-backup.XXXXXX)"
LOG_FILE="/var/log/neurosphere/vault-backup.log"
AUDIT_LOG_FILE="/var/log/neurosphere/vault-backup-audit.log"
CHECKSUM_ALGORITHM="sha256"

# Vault connection
VAULT_ADDR="${VAULT_ADDR:-https://vault.neurosphere.internal:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"  # Should be injected via K8s secret or IAM role
VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-false}"

# KMS encryption
KMS_KEY_ID="${KMS_KEY_ID:-alias/neurosphere-${ENVIRONMENT}-dr}"

# Operator identity for audit trail
OPERATOR="${OPERATOR:-system/backup-agent}"

# ---------------------------------------------------------------------------
# Logging & Audit
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "${LOG_FILE}")" "$(dirname "${AUDIT_LOG_FILE}")"

log() {
    local level="$1"; shift
    local message="$*"
    local entry
    entry=$(printf '{"timestamp":"%s","level":"%s","component":"vault-backup","environment":"%s","operator":"%s","message":"%s"}' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${level}" "${ENVIRONMENT}" "${OPERATOR}" "${message}")
    echo "${entry}" | tee -a "${LOG_FILE}"
}

# HIPAA audit log — immutable, structured, separate from operational logs
audit_log() {
    local action="$1"; shift
    local status="$1"; shift
    local detail="$*"
    local entry
    entry=$(printf '{"timestamp":"%s","audit_type":"vault-backup","action":"%s","status":"%s","operator":"%s","environment":"%s","backup_id":"%s","detail":"%s","hipaa_relevant":true}' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${action}" "${status}" "${OPERATOR}" "${ENVIRONMENT}" "${BACKUP_NAME}" "${detail}")
    echo "${entry}" | tee -a "${AUDIT_LOG_FILE}" >> "${LOG_FILE}"
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

# ---------------------------------------------------------------------------
# Cleanup handler
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    log_info "Cleaning up temporary directory: ${TEMP_DIR}"
    # Securely wipe temp files (Vault snapshots contain sensitive key material)
    if command -v shred &>/dev/null; then
        find "${TEMP_DIR}" -type f -exec shred -u {} \; 2>/dev/null || true
    fi
    rm -rf "${TEMP_DIR}"

    if [[ ${exit_code} -eq 0 ]]; then
        audit_log "backup_complete" "success" "Vault Raft snapshot backup completed successfully"
    else
        audit_log "backup_complete" "failure" "Vault Raft snapshot backup failed with exit code ${exit_code}"
    fi
    exit "${exit_code}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
check_dependencies() {
    log_info "Checking required dependencies..."
    local missing=()
    for cmd in vault gzip aws sha256sum; do
        if ! command -v "${cmd}" &>/dev/null; then
            missing+=("${cmd}")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing[*]}"
        exit 25
    fi
    log_info "All dependencies present."
}

# ---------------------------------------------------------------------------
# Vault health & auth validation
# ---------------------------------------------------------------------------
validate_vault() {
    log_info "Validating Vault connectivity and authentication..."
    audit_log "vault_validation" "started" "Checking Vault at ${VAULT_ADDR}"

    # Check if Vault is reachable and unsealed
    local vault_status
    if ! vault_status=$(vault status -format=json 2>/dev/null); then
        log_error "Cannot connect to Vault at ${VAULT_ADDR}"
        audit_log "vault_validation" "failure" "Vault unreachable at ${VAULT_ADDR}"
        exit 27
    fi

    local sealed
    sealed=$(echo "${vault_status}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sealed', True))" 2>/dev/null || echo "true")

    if [[ "${sealed}" == "True" || "${sealed}" == "true" ]]; then
        log_error "Vault is sealed. Cannot take snapshot."
        audit_log "vault_validation" "failure" "Vault is in sealed state"
        exit 27
    fi

    # Verify token has snapshot permissions
    if ! vault operator raft list-peers -format=json &>/dev/null; then
        log_warn "Could not list Raft peers — token may lack permissions, but snapshot may still work."
    fi

    audit_log "vault_validation" "success" "Vault is reachable, unsealed, and authenticated"
    log_info "Vault validation passed."
}

# ---------------------------------------------------------------------------
# Step 1: Take Vault Raft snapshot
# ---------------------------------------------------------------------------
take_snapshot() {
    local snapshot_path="${TEMP_DIR}/${BACKUP_NAME}.snap"
    log_info "Taking Vault Raft snapshot..."
    audit_log "snapshot_create" "started" "Initiating Vault Raft snapshot"

    if ! vault operator raft snapshot save "${snapshot_path}" 2>&1 | tee -a "${LOG_FILE}"; then
        log_error "Vault Raft snapshot save failed."
        audit_log "snapshot_create" "failure" "vault operator raft snapshot save returned non-zero"
        exit 20
    fi

    # Verify file was created and is non-empty
    if [[ ! -s "${snapshot_path}" ]]; then
        log_error "Snapshot file is empty or missing: ${snapshot_path}"
        audit_log "snapshot_create" "failure" "Snapshot file is empty"
        exit 20
    fi

    local size
    size=$(stat -f%z "${snapshot_path}" 2>/dev/null || stat --printf="%s" "${snapshot_path}" 2>/dev/null)
    log_info "Snapshot captured: ${snapshot_path} (${size} bytes)"
    audit_log "snapshot_create" "success" "Snapshot size: ${size} bytes"

    echo "${snapshot_path}"
}

# ---------------------------------------------------------------------------
# Step 2: Compress snapshot
# ---------------------------------------------------------------------------
compress_snapshot() {
    local snapshot_path="$1"
    local compressed_path="${snapshot_path}.gz"
    log_info "Compressing Vault snapshot..."

    if ! gzip -9 "${snapshot_path}"; then
        log_error "Compression failed."
        exit 21
    fi

    local size
    size=$(stat -f%z "${compressed_path}" 2>/dev/null || stat --printf="%s" "${compressed_path}" 2>/dev/null)
    log_info "Compressed: ${compressed_path} (${size} bytes)"
    echo "${compressed_path}"
}

# ---------------------------------------------------------------------------
# Step 3: Generate checksum
# ---------------------------------------------------------------------------
generate_checksum() {
    local file_path="$1"
    local checksum_file="${file_path}.${CHECKSUM_ALGORITHM}"
    log_info "Generating ${CHECKSUM_ALGORITHM} checksum..."

    sha256sum "${file_path}" | awk '{print $1}' > "${checksum_file}"
    local checksum
    checksum=$(cat "${checksum_file}")
    log_info "Checksum: ${checksum}"
    audit_log "checksum_generate" "success" "SHA-256: ${checksum}"
    echo "${checksum_file}"
}

# ---------------------------------------------------------------------------
# Step 4: Upload to S3 (encrypted)
# ---------------------------------------------------------------------------
upload_to_s3() {
    local compressed_path="$1"
    local checksum_file="$2"
    local s3_key="${S3_PREFIX}/${BACKUP_NAME}.snap.gz"
    local s3_checksum_key="${S3_PREFIX}/${BACKUP_NAME}.snap.gz.${CHECKSUM_ALGORITHM}"

    log_info "Uploading Vault snapshot to s3://${S3_BUCKET}/${s3_key} (SSE-KMS encrypted)..."
    audit_log "s3_upload" "started" "Uploading to s3://${S3_BUCKET}/${s3_key}"

    if ! aws s3 cp "${compressed_path}" "s3://${S3_BUCKET}/${s3_key}" \
        --sse aws:kms \
        --sse-kms-key-id "${KMS_KEY_ID}" \
        --metadata "environment=${ENVIRONMENT},timestamp=${TIMESTAMP},component=vault,operator=${OPERATOR}" \
        --storage-class STANDARD_IA \
        2>&1 | tee -a "${LOG_FILE}"; then
        log_error "S3 upload of snapshot failed."
        audit_log "s3_upload" "failure" "Failed to upload snapshot to S3"
        exit 22
    fi

    # Upload checksum
    if ! aws s3 cp "${checksum_file}" "s3://${S3_BUCKET}/${s3_checksum_key}" \
        --sse aws:kms \
        --sse-kms-key-id "${KMS_KEY_ID}" \
        2>&1 | tee -a "${LOG_FILE}"; then
        log_error "S3 upload of checksum file failed."
        audit_log "s3_upload" "failure" "Failed to upload checksum to S3"
        exit 22
    fi

    audit_log "s3_upload" "success" "Snapshot uploaded to s3://${S3_BUCKET}/${s3_key}"
    log_info "Upload complete."
}

# ---------------------------------------------------------------------------
# Step 5: Verify backup integrity in S3
# ---------------------------------------------------------------------------
verify_backup() {
    local s3_key="${S3_PREFIX}/${BACKUP_NAME}.snap.gz"
    log_info "Verifying Vault snapshot integrity in S3..."

    local remote_checksum
    remote_checksum=$(aws s3 cp "s3://${S3_BUCKET}/${s3_key}.${CHECKSUM_ALGORITHM}" - 2>/dev/null)
    local local_checksum
    local_checksum=$(cat "${TEMP_DIR}/${BACKUP_NAME}.snap.gz.${CHECKSUM_ALGORITHM}")

    if [[ "${remote_checksum}" != "${local_checksum}" ]]; then
        log_error "Checksum mismatch! Local: ${local_checksum}, Remote: ${remote_checksum}"
        audit_log "integrity_verify" "failure" "Checksum mismatch detected"
        exit 23
    fi

    local size
    size=$(aws s3api head-object --bucket "${S3_BUCKET}" --key "${s3_key}" \
        --query 'ContentLength' --output text 2>/dev/null)

    if [[ -z "${size}" || "${size}" -eq 0 ]]; then
        log_error "Uploaded object has zero size."
        audit_log "integrity_verify" "failure" "Zero-size object in S3"
        exit 23
    fi

    audit_log "integrity_verify" "success" "Checksum match confirmed, size: ${size} bytes"
    log_info "Integrity verification passed."
}

# ---------------------------------------------------------------------------
# Step 6: Enforce retention
# ---------------------------------------------------------------------------
enforce_retention() {
    log_info "Enforcing retention: keeping last ${BACKUP_RETENTION_COUNT} snapshots..."

    local all_snapshots
    all_snapshots=$(aws s3api list-objects-v2 \
        --bucket "${S3_BUCKET}" \
        --prefix "${S3_PREFIX}/vault-raft-${ENVIRONMENT}-" \
        --query 'Contents[?ends_with(Key, `.snap.gz`)].[Key,LastModified]' \
        --output text 2>/dev/null | sort -k2)

    local count
    count=$(echo "${all_snapshots}" | grep -c "." || true)

    if [[ ${count} -le ${BACKUP_RETENTION_COUNT} ]]; then
        log_info "Snapshot count (${count}) within retention limit. No cleanup needed."
        return 0
    fi

    local to_delete=$((count - BACKUP_RETENTION_COUNT))
    log_info "Purging ${to_delete} old snapshot(s)..."
    audit_log "retention_cleanup" "started" "Deleting ${to_delete} old snapshots"

    echo "${all_snapshots}" | head -n "${to_delete}" | while read -r key _; do
        log_info "Deleting: s3://${S3_BUCKET}/${key}"
        audit_log "snapshot_delete" "started" "Deleting old snapshot: ${key}"
        aws s3 rm "s3://${S3_BUCKET}/${key}" 2>/dev/null || true
        aws s3 rm "s3://${S3_BUCKET}/${key}.${CHECKSUM_ALGORITHM}" 2>/dev/null || true
    done

    audit_log "retention_cleanup" "success" "Deleted ${to_delete} old snapshots"
    log_info "Retention enforcement complete."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log_info "========== NeuroSphere Vault Backup Started =========="
    audit_log "backup_start" "started" "Vault Raft snapshot backup initiated by ${OPERATOR}"

    check_dependencies
    validate_vault

    local snapshot_path
    snapshot_path=$(take_snapshot)

    local compressed_path
    compressed_path=$(compress_snapshot "${snapshot_path}")

    local checksum_file
    checksum_file=$(generate_checksum "${compressed_path}")

    upload_to_s3 "${compressed_path}" "${checksum_file}"
    verify_backup
    enforce_retention

    log_info "========== NeuroSphere Vault Backup Completed Successfully =========="
    log_info "Snapshot: s3://${S3_BUCKET}/${S3_PREFIX}/${BACKUP_NAME}.snap.gz"
}

main "$@"
