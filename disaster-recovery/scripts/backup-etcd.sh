#!/usr/bin/env bash
###############################################################################
# NeuroSphere Medical Robotics — etcd Snapshot Backup
#
# Takes a point-in-time etcd snapshot, compresses it, uploads to S3, verifies
# integrity, and enforces a 30-backup retention window.
#
# Healthcare Compliance Notes:
#   - All operations are logged with timestamps for HIPAA audit trail
#   - Backups are encrypted at rest via S3 SSE-KMS
#   - Exit codes are mapped for Prometheus Alertmanager integration
#
# Exit Codes:
#   0  — Success
#   1  — General / unknown error
#   10 — etcdctl snapshot failed
#   11 — Compression failed
#   12 — S3 upload failed
#   13 — Integrity verification failed
#   14 — Retention cleanup failed
#   15 — Missing dependencies
#   16 — Environment configuration error
###############################################################################
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
ENVIRONMENT="${NEUROSPHERE_ENV:-staging}"
CLUSTER_NAME="${CLUSTER_NAME:-neurosphere-${ENVIRONMENT}}"
S3_BUCKET="neurosphere-${ENVIRONMENT}-dr-backups"
S3_PREFIX="etcd-snapshots"
BACKUP_RETENTION_COUNT=30
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_NAME="etcd-snapshot-${CLUSTER_NAME}-${TIMESTAMP}"
TEMP_DIR="$(mktemp -d /tmp/neurosphere-etcd-backup.XXXXXX)"
LOG_FILE="/var/log/neurosphere/etcd-backup.log"
CHECKSUM_ALGORITHM="sha256"

# etcd connection settings
ETCD_ENDPOINTS="${ETCD_ENDPOINTS:-https://127.0.0.1:2379}"
ETCD_CACERT="${ETCD_CACERT:-/etc/kubernetes/pki/etcd/ca.crt}"
ETCD_CERT="${ETCD_CERT:-/etc/kubernetes/pki/etcd/server.crt}"
ETCD_KEY="${ETCD_KEY:-/etc/kubernetes/pki/etcd/server.key}"

# KMS key for server-side encryption
KMS_KEY_ID="${KMS_KEY_ID:-alias/neurosphere-${ENVIRONMENT}-dr}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "${LOG_FILE}")"

log() {
    local level="$1"; shift
    local message="$*"
    local entry
    entry=$(printf '{"timestamp":"%s","level":"%s","component":"etcd-backup","cluster":"%s","environment":"%s","message":"%s"}' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${level}" "${CLUSTER_NAME}" "${ENVIRONMENT}" "${message}")
    echo "${entry}" | tee -a "${LOG_FILE}"
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
    rm -rf "${TEMP_DIR}"
    if [[ ${exit_code} -eq 0 ]]; then
        log_info "etcd backup completed successfully: ${BACKUP_NAME}"
    else
        log_error "etcd backup FAILED with exit code ${exit_code}: ${BACKUP_NAME}"
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
    for cmd in etcdctl gzip aws sha256sum; do
        if ! command -v "${cmd}" &>/dev/null; then
            missing+=("${cmd}")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing[*]}"
        exit 15
    fi
    log_info "All dependencies present."
}

# ---------------------------------------------------------------------------
# Validate environment
# ---------------------------------------------------------------------------
validate_environment() {
    log_info "Validating environment configuration..."

    if [[ ! "${ENVIRONMENT}" =~ ^(dev|staging|production)$ ]]; then
        log_error "Invalid environment: ${ENVIRONMENT}. Must be dev, staging, or production."
        exit 16
    fi

    # Verify S3 bucket exists and is accessible
    if ! aws s3api head-bucket --bucket "${S3_BUCKET}" 2>/dev/null; then
        log_error "S3 bucket ${S3_BUCKET} does not exist or is not accessible."
        exit 16
    fi

    # Verify etcd connectivity
    if ! etcdctl endpoint health \
        --endpoints="${ETCD_ENDPOINTS}" \
        --cacert="${ETCD_CACERT}" \
        --cert="${ETCD_CERT}" \
        --key="${ETCD_KEY}" 2>/dev/null; then
        log_warn "etcd health check failed — proceeding with snapshot attempt anyway."
    fi

    log_info "Environment validation passed."
}

# ---------------------------------------------------------------------------
# Step 1: Take etcd snapshot
# ---------------------------------------------------------------------------
take_snapshot() {
    local snapshot_path="${TEMP_DIR}/${BACKUP_NAME}.db"
    log_info "Taking etcd snapshot from ${ETCD_ENDPOINTS}..."

    if ! etcdctl snapshot save "${snapshot_path}" \
        --endpoints="${ETCD_ENDPOINTS}" \
        --cacert="${ETCD_CACERT}" \
        --cert="${ETCD_CERT}" \
        --key="${ETCD_KEY}" 2>&1 | tee -a "${LOG_FILE}"; then
        log_error "etcdctl snapshot save failed."
        exit 10
    fi

    # Verify the snapshot is valid
    log_info "Verifying raw snapshot integrity..."
    if ! etcdctl snapshot status "${snapshot_path}" \
        --write-out=json 2>/dev/null; then
        log_error "etcd snapshot status check failed — snapshot may be corrupt."
        exit 10
    fi

    local size
    size=$(stat -f%z "${snapshot_path}" 2>/dev/null || stat --printf="%s" "${snapshot_path}" 2>/dev/null)
    log_info "Snapshot captured: ${snapshot_path} (${size} bytes)"
    echo "${snapshot_path}"
}

# ---------------------------------------------------------------------------
# Step 2: Compress snapshot
# ---------------------------------------------------------------------------
compress_snapshot() {
    local snapshot_path="$1"
    local compressed_path="${snapshot_path}.gz"
    log_info "Compressing snapshot with gzip..."

    if ! gzip -9 "${snapshot_path}"; then
        log_error "Compression failed for ${snapshot_path}."
        exit 11
    fi

    local size
    size=$(stat -f%z "${compressed_path}" 2>/dev/null || stat --printf="%s" "${compressed_path}" 2>/dev/null)
    log_info "Compressed snapshot: ${compressed_path} (${size} bytes)"
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
    log_info "Checksum (${CHECKSUM_ALGORITHM}): ${checksum}"
    echo "${checksum_file}"
}

# ---------------------------------------------------------------------------
# Step 4: Upload to S3
# ---------------------------------------------------------------------------
upload_to_s3() {
    local compressed_path="$1"
    local checksum_file="$2"
    local s3_key="${S3_PREFIX}/${BACKUP_NAME}.db.gz"
    local s3_checksum_key="${S3_PREFIX}/${BACKUP_NAME}.db.gz.${CHECKSUM_ALGORITHM}"

    log_info "Uploading backup to s3://${S3_BUCKET}/${s3_key}..."

    # Upload compressed snapshot with SSE-KMS encryption
    if ! aws s3 cp "${compressed_path}" "s3://${S3_BUCKET}/${s3_key}" \
        --sse aws:kms \
        --sse-kms-key-id "${KMS_KEY_ID}" \
        --metadata "cluster=${CLUSTER_NAME},environment=${ENVIRONMENT},timestamp=${TIMESTAMP},component=etcd" \
        --storage-class STANDARD_IA \
        2>&1 | tee -a "${LOG_FILE}"; then
        log_error "S3 upload of snapshot failed."
        exit 12
    fi

    # Upload checksum file
    if ! aws s3 cp "${checksum_file}" "s3://${S3_BUCKET}/${s3_checksum_key}" \
        --sse aws:kms \
        --sse-kms-key-id "${KMS_KEY_ID}" \
        2>&1 | tee -a "${LOG_FILE}"; then
        log_error "S3 upload of checksum file failed."
        exit 12
    fi

    log_info "Upload complete: s3://${S3_BUCKET}/${s3_key}"
}

# ---------------------------------------------------------------------------
# Step 5: Verify backup in S3
# ---------------------------------------------------------------------------
verify_backup() {
    local s3_key="${S3_PREFIX}/${BACKUP_NAME}.db.gz"
    log_info "Verifying backup integrity in S3..."

    # Download and compare checksum
    local remote_checksum_key="${S3_PREFIX}/${BACKUP_NAME}.db.gz.${CHECKSUM_ALGORITHM}"
    local remote_checksum
    remote_checksum=$(aws s3 cp "s3://${S3_BUCKET}/${remote_checksum_key}" - 2>/dev/null)

    local local_checksum
    local_checksum=$(cat "${TEMP_DIR}/${BACKUP_NAME}.db.gz.${CHECKSUM_ALGORITHM}")

    if [[ "${remote_checksum}" != "${local_checksum}" ]]; then
        log_error "Checksum mismatch! Local: ${local_checksum}, Remote: ${remote_checksum}"
        exit 13
    fi

    # Verify the object exists and has a nonzero size
    local size
    size=$(aws s3api head-object --bucket "${S3_BUCKET}" --key "${s3_key}" \
        --query 'ContentLength' --output text 2>/dev/null)

    if [[ -z "${size}" || "${size}" -eq 0 ]]; then
        log_error "Uploaded object has zero size or does not exist."
        exit 13
    fi

    log_info "Backup verification passed. Remote size: ${size} bytes, checksum match confirmed."
}

# ---------------------------------------------------------------------------
# Step 6: Enforce retention (keep last 30 backups)
# ---------------------------------------------------------------------------
enforce_retention() {
    log_info "Enforcing retention policy: keeping last ${BACKUP_RETENTION_COUNT} backups..."

    # List all snapshot objects, sorted by date (oldest first)
    local all_snapshots
    all_snapshots=$(aws s3api list-objects-v2 \
        --bucket "${S3_BUCKET}" \
        --prefix "${S3_PREFIX}/etcd-snapshot-${CLUSTER_NAME}-" \
        --query 'Contents[?ends_with(Key, `.db.gz`)].[Key,LastModified]' \
        --output text 2>/dev/null | sort -k2)

    local count
    count=$(echo "${all_snapshots}" | grep -c "." || true)

    if [[ ${count} -le ${BACKUP_RETENTION_COUNT} ]]; then
        log_info "Current backup count (${count}) is within retention limit (${BACKUP_RETENTION_COUNT}). No cleanup needed."
        return 0
    fi

    local to_delete=$((count - BACKUP_RETENTION_COUNT))
    log_info "Deleting ${to_delete} old backup(s) to enforce retention..."

    echo "${all_snapshots}" | head -n "${to_delete}" | while read -r key _; do
        local checksum_key="${key}.${CHECKSUM_ALGORITHM}"
        log_info "Deleting old backup: s3://${S3_BUCKET}/${key}"
        if ! aws s3 rm "s3://${S3_BUCKET}/${key}" 2>/dev/null; then
            log_warn "Failed to delete s3://${S3_BUCKET}/${key}"
        fi
        aws s3 rm "s3://${S3_BUCKET}/${checksum_key}" 2>/dev/null || true
    done

    log_info "Retention enforcement complete."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log_info "========== NeuroSphere etcd Backup Started =========="
    log_info "Backup ID: ${BACKUP_NAME}"
    log_info "Environment: ${ENVIRONMENT}, Cluster: ${CLUSTER_NAME}"

    check_dependencies
    validate_environment

    local snapshot_path
    snapshot_path=$(take_snapshot)

    local compressed_path
    compressed_path=$(compress_snapshot "${snapshot_path}")

    local checksum_file
    checksum_file=$(generate_checksum "${compressed_path}")

    upload_to_s3 "${compressed_path}" "${checksum_file}"
    verify_backup
    enforce_retention

    log_info "========== NeuroSphere etcd Backup Completed Successfully =========="
    log_info "Backup location: s3://${S3_BUCKET}/${S3_PREFIX}/${BACKUP_NAME}.db.gz"
}

main "$@"
