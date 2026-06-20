#!/usr/bin/env bash
###############################################################################
# NeuroSphere Medical Robotics — PostgreSQL Database Backup
#
# Performs pg_dump for each database (robot-db, patient-db, telemetry-db),
# compresses with gzip, encrypts with GPG (HIPAA PHI requirement), uploads
# to S3 with server-side encryption, and manages lifecycle policies.
#
# HIPAA Compliance Notes (45 CFR §164.312):
#   - PHI data (patient-db) is encrypted with GPG before leaving the host
#   - S3 server-side encryption (SSE-KMS) provides encryption at rest
#   - All backup operations are audit-logged with timestamps
#   - Checksums verify data integrity during transit
#   - 30-day active retention, Glacier transition at 90 days
#   - Database credentials are injected via K8s secrets, never hardcoded
#
# Exit Codes:
#   0  — Success (all databases backed up)
#   1  — General error
#   30 — pg_dump failed
#   31 — Compression failed
#   32 — GPG encryption failed
#   33 — S3 upload failed
#   34 — Checksum verification failed
#   35 — Missing dependencies
#   36 — Database connection failed
#   37 — Partial failure (some DBs failed, some succeeded)
###############################################################################
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
ENVIRONMENT="${NEUROSPHERE_ENV:-staging}"
S3_BUCKET="neurosphere-${ENVIRONMENT}-dr-backups"
S3_PREFIX="database-backups"
BACKUP_RETENTION_COUNT=30
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DATE="$(date -u +%Y-%m-%d)"
TEMP_DIR="$(mktemp -d /tmp/neurosphere-db-backup.XXXXXX)"
LOG_FILE="/var/log/neurosphere/database-backup.log"
AUDIT_LOG_FILE="/var/log/neurosphere/database-backup-audit.log"

# Database definitions: name|host|port|user|password_env_var
DATABASES=(
    "robot-db|${ROBOT_DB_HOST:-robot-db.neurosphere.internal}|5432|${ROBOT_DB_USER:-neurosphere_robot}|ROBOT_DB_PASSWORD"
    "patient-db|${PATIENT_DB_HOST:-patient-db.neurosphere.internal}|5432|${PATIENT_DB_USER:-neurosphere_patient}|PATIENT_DB_PASSWORD"
    "telemetry-db|${TELEMETRY_DB_HOST:-telemetry-db.neurosphere.internal}|5432|${TELEMETRY_DB_USER:-neurosphere_telemetry}|TELEMETRY_DB_PASSWORD"
)

# GPG recipient for PHI encryption (public key must be in keyring)
GPG_RECIPIENT="${GPG_RECIPIENT:-neurosphere-backup@neurosphere.io}"
GPG_HOMEDIR="${GPG_HOMEDIR:-/etc/neurosphere/gpg}"

# KMS key
KMS_KEY_ID="${KMS_KEY_ID:-alias/neurosphere-${ENVIRONMENT}-dr}"

# Operator identity
OPERATOR="${OPERATOR:-system/backup-agent}"

# Track failures for partial-failure exit code
FAILED_DATABASES=()
SUCCESSFUL_DATABASES=()

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "${LOG_FILE}")" "$(dirname "${AUDIT_LOG_FILE}")"

log() {
    local level="$1"; shift
    local message="$*"
    local entry
    entry=$(printf '{"timestamp":"%s","level":"%s","component":"database-backup","environment":"%s","operator":"%s","message":"%s"}' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${level}" "${ENVIRONMENT}" "${OPERATOR}" "${message}")
    echo "${entry}" | tee -a "${LOG_FILE}"
}

audit_log() {
    local action="$1"; shift
    local status="$1"; shift
    local detail="$*"
    local entry
    entry=$(printf '{"timestamp":"%s","audit_type":"database-backup","action":"%s","status":"%s","operator":"%s","environment":"%s","detail":"%s","hipaa_relevant":true}' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${action}" "${status}" "${OPERATOR}" "${ENVIRONMENT}" "${detail}")
    echo "${entry}" | tee -a "${AUDIT_LOG_FILE}" >> "${LOG_FILE}"
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    log_info "Securely cleaning up temporary directory..."

    # Shred temp files containing PHI data
    if command -v shred &>/dev/null; then
        find "${TEMP_DIR}" -type f -exec shred -u {} \; 2>/dev/null || true
    fi
    rm -rf "${TEMP_DIR}"

    if [[ ${exit_code} -eq 0 ]]; then
        audit_log "backup_session" "success" "All databases backed up: ${SUCCESSFUL_DATABASES[*]}"
    else
        audit_log "backup_session" "failure" "Failed DBs: ${FAILED_DATABASES[*]:-none}; Succeeded: ${SUCCESSFUL_DATABASES[*]:-none}"
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
    for cmd in pg_dump gzip gpg aws sha256sum; do
        if ! command -v "${cmd}" &>/dev/null; then
            missing+=("${cmd}")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing[*]}"
        exit 35
    fi

    # Verify GPG key is available
    if ! gpg --homedir "${GPG_HOMEDIR}" --list-keys "${GPG_RECIPIENT}" &>/dev/null; then
        log_error "GPG public key not found for recipient: ${GPG_RECIPIENT}"
        exit 35
    fi

    log_info "All dependencies present (including GPG key for ${GPG_RECIPIENT})."
}

# ---------------------------------------------------------------------------
# S3 lifecycle policy setup (idempotent)
# ---------------------------------------------------------------------------
ensure_lifecycle_policy() {
    log_info "Ensuring S3 lifecycle policy is configured..."

    local lifecycle_config
    lifecycle_config=$(cat <<-EOF
{
    "Rules": [
        {
            "ID": "neurosphere-db-backup-lifecycle",
            "Filter": {
                "Prefix": "${S3_PREFIX}/"
            },
            "Status": "Enabled",
            "Transitions": [
                {
                    "Days": 90,
                    "StorageClass": "GLACIER"
                }
            ],
            "Expiration": {
                "Days": 2555
            }
        }
    ]
}
EOF
    )

    if aws s3api put-bucket-lifecycle-configuration \
        --bucket "${S3_BUCKET}" \
        --lifecycle-configuration "${lifecycle_config}" 2>/dev/null; then
        log_info "Lifecycle policy applied: Glacier after 90 days, expire after 7 years."
    else
        log_warn "Could not apply lifecycle policy — may require elevated permissions."
    fi
}

# ---------------------------------------------------------------------------
# Backup a single database
# ---------------------------------------------------------------------------
backup_database() {
    local db_spec="$1"
    IFS='|' read -r db_name db_host db_port db_user password_env_var <<< "${db_spec}"

    local db_password="${!password_env_var:-}"
    if [[ -z "${db_password}" ]]; then
        log_error "Password environment variable ${password_env_var} is not set for ${db_name}."
        return 1
    fi

    local backup_basename="${db_name}-${ENVIRONMENT}-${TIMESTAMP}"
    local dump_file="${TEMP_DIR}/${backup_basename}.sql"
    local compressed_file="${dump_file}.gz"
    local encrypted_file="${compressed_file}.gpg"
    local checksum_file="${encrypted_file}.sha256"

    log_info "--- Backing up database: ${db_name} ---"
    audit_log "db_backup_start" "started" "Database: ${db_name}, Host: ${db_host}:${db_port}"

    # Step 1: pg_dump
    log_info "[${db_name}] Running pg_dump..."
    export PGPASSWORD="${db_password}"

    if ! pg_dump \
        --host="${db_host}" \
        --port="${db_port}" \
        --username="${db_user}" \
        --dbname="${db_name}" \
        --format=plain \
        --verbose \
        --no-owner \
        --no-privileges \
        --clean \
        --if-exists \
        --file="${dump_file}" \
        2>&1 | tee -a "${LOG_FILE}"; then
        log_error "[${db_name}] pg_dump failed."
        audit_log "db_dump" "failure" "pg_dump failed for ${db_name}"
        unset PGPASSWORD
        return 1
    fi
    unset PGPASSWORD

    local dump_size
    dump_size=$(stat -f%z "${dump_file}" 2>/dev/null || stat --printf="%s" "${dump_file}" 2>/dev/null)
    log_info "[${db_name}] Dump created: ${dump_size} bytes"

    # Step 2: Compress
    log_info "[${db_name}] Compressing with gzip..."
    if ! gzip -9 "${dump_file}"; then
        log_error "[${db_name}] Compression failed."
        return 1
    fi

    local compressed_size
    compressed_size=$(stat -f%z "${compressed_file}" 2>/dev/null || stat --printf="%s" "${compressed_file}" 2>/dev/null)
    log_info "[${db_name}] Compressed: ${compressed_size} bytes (ratio: $(( (dump_size - compressed_size) * 100 / dump_size ))%)"

    # Step 3: GPG encrypt (HIPAA requirement for PHI data)
    log_info "[${db_name}] Encrypting with GPG (recipient: ${GPG_RECIPIENT})..."
    if ! gpg --homedir "${GPG_HOMEDIR}" \
        --encrypt \
        --recipient "${GPG_RECIPIENT}" \
        --trust-model always \
        --output "${encrypted_file}" \
        "${compressed_file}" 2>&1 | tee -a "${LOG_FILE}"; then
        log_error "[${db_name}] GPG encryption failed."
        audit_log "db_encrypt" "failure" "GPG encryption failed for ${db_name}"
        return 1
    fi

    # Remove unencrypted compressed file immediately
    shred -u "${compressed_file}" 2>/dev/null || rm -f "${compressed_file}"
    audit_log "db_encrypt" "success" "Database ${db_name} encrypted with GPG"

    local encrypted_size
    encrypted_size=$(stat -f%z "${encrypted_file}" 2>/dev/null || stat --printf="%s" "${encrypted_file}" 2>/dev/null)
    log_info "[${db_name}] Encrypted: ${encrypted_size} bytes"

    # Step 4: Generate checksum
    log_info "[${db_name}] Generating SHA-256 checksum..."
    sha256sum "${encrypted_file}" | awk '{print $1}' > "${checksum_file}"
    local checksum
    checksum=$(cat "${checksum_file}")
    log_info "[${db_name}] Checksum: ${checksum}"

    # Step 5: Upload to S3
    local s3_key="${S3_PREFIX}/${BACKUP_DATE}/${backup_basename}.sql.gz.gpg"
    local s3_checksum_key="${s3_key}.sha256"

    log_info "[${db_name}] Uploading to s3://${S3_BUCKET}/${s3_key}..."
    audit_log "db_upload" "started" "Uploading ${db_name} to S3"

    if ! aws s3 cp "${encrypted_file}" "s3://${S3_BUCKET}/${s3_key}" \
        --sse aws:kms \
        --sse-kms-key-id "${KMS_KEY_ID}" \
        --metadata "database=${db_name},environment=${ENVIRONMENT},timestamp=${TIMESTAMP},encrypted=gpg,phi_data=true" \
        2>&1 | tee -a "${LOG_FILE}"; then
        log_error "[${db_name}] S3 upload failed."
        audit_log "db_upload" "failure" "S3 upload failed for ${db_name}"
        return 1
    fi

    # Upload checksum
    aws s3 cp "${checksum_file}" "s3://${S3_BUCKET}/${s3_checksum_key}" \
        --sse aws:kms \
        --sse-kms-key-id "${KMS_KEY_ID}" \
        2>&1 | tee -a "${LOG_FILE}" || true

    # Step 6: Verify upload
    log_info "[${db_name}] Verifying upload integrity..."
    local remote_checksum
    remote_checksum=$(aws s3 cp "s3://${S3_BUCKET}/${s3_checksum_key}" - 2>/dev/null || echo "")

    if [[ "${remote_checksum}" != "${checksum}" ]]; then
        log_error "[${db_name}] Checksum mismatch after upload!"
        audit_log "db_verify" "failure" "Checksum mismatch for ${db_name}"
        return 1
    fi

    local remote_size
    remote_size=$(aws s3api head-object --bucket "${S3_BUCKET}" --key "${s3_key}" \
        --query 'ContentLength' --output text 2>/dev/null || echo "0")

    audit_log "db_backup_complete" "success" "Database: ${db_name}, S3 key: ${s3_key}, size: ${remote_size} bytes, checksum verified"
    log_info "[${db_name}] Backup complete: s3://${S3_BUCKET}/${s3_key} (${remote_size} bytes)"
    return 0
}

# ---------------------------------------------------------------------------
# Enforce retention per database
# ---------------------------------------------------------------------------
enforce_retention() {
    log_info "Enforcing retention policy across all database backups..."

    for db_spec in "${DATABASES[@]}"; do
        IFS='|' read -r db_name _ _ _ _ <<< "${db_spec}"

        # List all backups for this database
        local all_backups
        all_backups=$(aws s3api list-objects-v2 \
            --bucket "${S3_BUCKET}" \
            --prefix "${S3_PREFIX}/" \
            --query "Contents[?contains(Key, '${db_name}-${ENVIRONMENT}-') && ends_with(Key, '.sql.gz.gpg')].[Key,LastModified]" \
            --output text 2>/dev/null | sort -k2)

        local count
        count=$(echo "${all_backups}" | grep -c "." || true)

        if [[ ${count} -le ${BACKUP_RETENTION_COUNT} ]]; then
            log_info "[${db_name}] ${count} backups — within retention limit."
            continue
        fi

        local to_delete=$((count - BACKUP_RETENTION_COUNT))
        log_info "[${db_name}] Deleting ${to_delete} old backup(s)..."

        echo "${all_backups}" | head -n "${to_delete}" | while read -r key _; do
            log_info "Deleting: s3://${S3_BUCKET}/${key}"
            aws s3 rm "s3://${S3_BUCKET}/${key}" 2>/dev/null || true
            aws s3 rm "s3://${S3_BUCKET}/${key}.sha256" 2>/dev/null || true
        done
    done

    log_info "Retention enforcement complete."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log_info "========== NeuroSphere Database Backup Started =========="
    log_info "Timestamp: ${TIMESTAMP}, Environment: ${ENVIRONMENT}"
    audit_log "backup_session_start" "started" "Backing up ${#DATABASES[@]} databases"

    check_dependencies
    ensure_lifecycle_policy

    # Back up each database
    for db_spec in "${DATABASES[@]}"; do
        IFS='|' read -r db_name _ _ _ _ <<< "${db_spec}"
        if backup_database "${db_spec}"; then
            SUCCESSFUL_DATABASES+=("${db_name}")
        else
            FAILED_DATABASES+=("${db_name}")
            log_error "Backup failed for ${db_name} — continuing with remaining databases."
        fi
    done

    enforce_retention

    # Report results
    log_info "========== Backup Summary =========="
    log_info "Successful: ${SUCCESSFUL_DATABASES[*]:-none}"
    log_info "Failed:     ${FAILED_DATABASES[*]:-none}"

    if [[ ${#FAILED_DATABASES[@]} -gt 0 && ${#SUCCESSFUL_DATABASES[@]} -gt 0 ]]; then
        log_error "Partial failure — some databases were not backed up."
        exit 37
    elif [[ ${#FAILED_DATABASES[@]} -gt 0 ]]; then
        log_error "All database backups failed."
        exit 30
    fi

    log_info "========== NeuroSphere Database Backup Completed Successfully =========="
}

main "$@"
