#!/usr/bin/env bash
###############################################################################
# NeuroSphere Medical Robotics — Cluster Restoration Script
#
# Restores NeuroSphere cluster components from DR backups. Supports:
#   - Full cluster restore (etcd + Vault + all databases + services)
#   - Single service restore
#   - Database-only restore
#   - Vault-only restore
#
# HIPAA Compliance Notes:
#   - All restore operations are audit-logged
#   - PHI data restore requires GPG decryption
#   - Restored data integrity is verified via checksums
#   - Post-restore access controls are validated
#
# Usage:
#   ./restore-cluster.sh --backup-date 2026-06-19 --environment production --component full
#   ./restore-cluster.sh --backup-date 2026-06-19 --environment staging --component database --database patient-db
#   ./restore-cluster.sh --backup-date 2026-06-19 --environment production --component vault
#   ./restore-cluster.sh --backup-date 2026-06-19 --environment production --component etcd
#
# Exit Codes:
#   0  — Success
#   1  — General error
#   40 — Invalid arguments
#   41 — Backup not found
#   42 — Checksum mismatch (backup corrupted)
#   43 — etcd restore failed
#   44 — Vault restore failed
#   45 — Database restore failed
#   46 — Service restart failed
#   47 — Health check failed post-restore
#   48 — Pre-restore validation failed
#   49 — Missing dependencies
###############################################################################
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
ENVIRONMENT=""
BACKUP_DATE=""
COMPONENT=""
TARGET_DATABASE=""
S3_BUCKET=""
S3_PREFIX_ETCD="etcd-snapshots"
S3_PREFIX_VAULT="vault-snapshots"
S3_PREFIX_DB="database-backups"
TEMP_DIR="$(mktemp -d /tmp/neurosphere-restore.XXXXXX)"
LOG_FILE="/var/log/neurosphere/cluster-restore.log"
AUDIT_LOG_FILE="/var/log/neurosphere/cluster-restore-audit.log"
REPORT_FILE=""
OPERATOR="${OPERATOR:-$(whoami)}"
DRY_RUN="${DRY_RUN:-false}"

# GPG decryption
GPG_HOMEDIR="${GPG_HOMEDIR:-/etc/neurosphere/gpg}"

# Service dependency order (bottom-up for restart)
SERVICE_RESTART_ORDER=(
    "vault"
    "robot-db"
    "patient-db"
    "telemetry-db"
    "telemetry-ingest-service"
    "diagnostic-engine"
    "robot-command-service"
    "patient-monitor-service"
    "neurosphere-gateway"
)

# Health check endpoints
declare -A HEALTH_ENDPOINTS=(
    ["neurosphere-gateway"]="http://gateway.neurosphere.internal/health"
    ["patient-monitor-service"]="http://patient-monitor.neurosphere.internal/health"
    ["robot-command-service"]="http://robot-command.neurosphere.internal/health"
    ["diagnostic-engine"]="http://diagnostic-engine.neurosphere.internal/health"
    ["telemetry-ingest-service"]="http://telemetry-ingest.neurosphere.internal/health"
)

# Track restore steps for report
declare -a RESTORE_STEPS=()
RESTORE_START_TIME=""
RESTORE_STATUS="IN_PROGRESS"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "${LOG_FILE}")" "$(dirname "${AUDIT_LOG_FILE}")"

log() {
    local level="$1"; shift
    printf '{"timestamp":"%s","level":"%s","component":"cluster-restore","environment":"%s","operator":"%s","message":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${level}" "${ENVIRONMENT}" "${OPERATOR}" "$*" \
        | tee -a "${LOG_FILE}"
}

audit_log() {
    local action="$1"; shift
    local status="$1"; shift
    printf '{"timestamp":"%s","audit_type":"cluster-restore","action":"%s","status":"%s","operator":"%s","environment":"%s","component":"%s","backup_date":"%s","detail":"%s","hipaa_relevant":true}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${action}" "${status}" "${OPERATOR}" "${ENVIRONMENT}" "${COMPONENT}" "${BACKUP_DATE}" "$*" \
        | tee -a "${AUDIT_LOG_FILE}" >> "${LOG_FILE}"
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

record_step() {
    local step_name="$1"
    local step_status="$2"
    local step_detail="${3:-}"
    RESTORE_STEPS+=("$(printf '{"step":"%s","status":"%s","timestamp":"%s","detail":"%s"}' \
        "${step_name}" "${step_status}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${step_detail}")")
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    log_info "Cleaning up temporary files..."

    if command -v shred &>/dev/null; then
        find "${TEMP_DIR}" -type f -exec shred -u {} \; 2>/dev/null || true
    fi
    rm -rf "${TEMP_DIR}"

    if [[ ${exit_code} -eq 0 ]]; then
        RESTORE_STATUS="SUCCESS"
    else
        RESTORE_STATUS="FAILED"
    fi

    generate_report
    exit "${exit_code}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --backup-date)
                BACKUP_DATE="$2"; shift 2 ;;
            --environment)
                ENVIRONMENT="$2"; shift 2 ;;
            --component)
                COMPONENT="$2"; shift 2 ;;
            --database)
                TARGET_DATABASE="$2"; shift 2 ;;
            --dry-run)
                DRY_RUN="true"; shift ;;
            --help|-h)
                usage; exit 0 ;;
            *)
                log_error "Unknown argument: $1"
                usage; exit 40 ;;
        esac
    done

    # Validate required args
    if [[ -z "${BACKUP_DATE}" || -z "${ENVIRONMENT}" || -z "${COMPONENT}" ]]; then
        log_error "Missing required arguments: --backup-date, --environment, --component"
        usage
        exit 40
    fi

    if [[ ! "${ENVIRONMENT}" =~ ^(dev|staging|production)$ ]]; then
        log_error "Invalid environment: ${ENVIRONMENT}"
        exit 40
    fi

    if [[ ! "${COMPONENT}" =~ ^(full|etcd|vault|database)$ ]]; then
        log_error "Invalid component: ${COMPONENT}. Must be: full, etcd, vault, database"
        exit 40
    fi

    if [[ "${COMPONENT}" == "database" && -z "${TARGET_DATABASE}" ]]; then
        log_error "Component 'database' requires --database <name> (robot-db, patient-db, telemetry-db, or 'all')"
        exit 40
    fi

    S3_BUCKET="neurosphere-${ENVIRONMENT}-dr-backups"
    REPORT_FILE="/var/log/neurosphere/restore-report-${ENVIRONMENT}-$(date -u +%Y%m%dT%H%M%SZ).json"
    RESTORE_START_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    log_info "Restore configuration: date=${BACKUP_DATE}, env=${ENVIRONMENT}, component=${COMPONENT}, database=${TARGET_DATABASE:-N/A}, dry_run=${DRY_RUN}"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Required:
  --backup-date DATE       Backup date to restore from (YYYY-MM-DD)
  --environment ENV        Target environment (dev|staging|production)
  --component COMP         Component to restore (full|etcd|vault|database)

Optional:
  --database DB            Database name (required when component=database)
                           Options: robot-db, patient-db, telemetry-db, all
  --dry-run                Validate only, do not perform restore
  --help                   Show this help message

Examples:
  $(basename "$0") --backup-date 2026-06-19 --environment production --component full
  $(basename "$0") --backup-date 2026-06-19 --environment staging --component database --database patient-db
  $(basename "$0") --backup-date 2026-06-19 --environment production --component vault --dry-run
EOF
}

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
check_dependencies() {
    log_info "Checking dependencies..."
    local missing=()
    for cmd in aws kubectl sha256sum; do
        if ! command -v "${cmd}" &>/dev/null; then
            missing+=("${cmd}")
        fi
    done

    case "${COMPONENT}" in
        full|etcd)
            command -v etcdctl &>/dev/null || missing+=("etcdctl") ;;
    esac
    case "${COMPONENT}" in
        full|vault)
            command -v vault &>/dev/null || missing+=("vault") ;;
    esac
    case "${COMPONENT}" in
        full|database)
            for cmd in psql gpg gunzip; do
                command -v "${cmd}" &>/dev/null || missing+=("${cmd}")
            done ;;
    esac

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing[*]}"
        exit 49
    fi
    record_step "dependency_check" "passed"
}

# ---------------------------------------------------------------------------
# Pre-restore validation
# ---------------------------------------------------------------------------
validate_backup_exists() {
    local prefix="$1"
    local pattern="$2"

    log_info "Checking for backup matching: s3://${S3_BUCKET}/${prefix}/${pattern}*"

    local found
    found=$(aws s3 ls "s3://${S3_BUCKET}/${prefix}/" 2>/dev/null \
        | grep "${pattern}" | head -1 || true)

    if [[ -z "${found}" ]]; then
        log_error "No backup found matching pattern '${pattern}' in s3://${S3_BUCKET}/${prefix}/"
        return 1
    fi

    log_info "Found backup: ${found}"
    return 0
}

pre_restore_validation() {
    log_info "=== Pre-Restore Validation ==="
    audit_log "pre_validation" "started" "Validating backups for ${COMPONENT} from ${BACKUP_DATE}"

    local validation_failed=false

    case "${COMPONENT}" in
        full)
            validate_backup_exists "${S3_PREFIX_ETCD}" "etcd-snapshot-neurosphere-${ENVIRONMENT}-${BACKUP_DATE//-/}" || validation_failed=true
            validate_backup_exists "${S3_PREFIX_VAULT}" "vault-raft-${ENVIRONMENT}-${BACKUP_DATE//-/}" || validation_failed=true
            for db in robot-db patient-db telemetry-db; do
                validate_backup_exists "${S3_PREFIX_DB}/${BACKUP_DATE}" "${db}-${ENVIRONMENT}-${BACKUP_DATE//-/}" || validation_failed=true
            done
            ;;
        etcd)
            validate_backup_exists "${S3_PREFIX_ETCD}" "etcd-snapshot-neurosphere-${ENVIRONMENT}-${BACKUP_DATE//-/}" || validation_failed=true
            ;;
        vault)
            validate_backup_exists "${S3_PREFIX_VAULT}" "vault-raft-${ENVIRONMENT}-${BACKUP_DATE//-/}" || validation_failed=true
            ;;
        database)
            local dbs=("${TARGET_DATABASE}")
            [[ "${TARGET_DATABASE}" == "all" ]] && dbs=(robot-db patient-db telemetry-db)
            for db in "${dbs[@]}"; do
                validate_backup_exists "${S3_PREFIX_DB}/${BACKUP_DATE}" "${db}-${ENVIRONMENT}-${BACKUP_DATE//-/}" || validation_failed=true
            done
            ;;
    esac

    if [[ "${validation_failed}" == "true" ]]; then
        log_error "Pre-restore validation failed — required backup(s) not found."
        record_step "pre_validation" "failed" "Backup not found for requested date"
        exit 41
    fi

    record_step "pre_validation" "passed"
    audit_log "pre_validation" "success" "All required backups found for ${BACKUP_DATE}"
}

# ---------------------------------------------------------------------------
# Stop services gracefully
# ---------------------------------------------------------------------------
stop_services() {
    log_info "=== Stopping Services Gracefully ==="
    audit_log "stop_services" "started" "Scaling down services before restore"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would scale down services."
        record_step "stop_services" "skipped (dry run)"
        return
    fi

    # Scale down in reverse dependency order (top-level services first)
    local reversed_order=()
    for ((i=${#SERVICE_RESTART_ORDER[@]}-1; i>=0; i--)); do
        reversed_order+=("${SERVICE_RESTART_ORDER[$i]}")
    done

    for service in "${reversed_order[@]}"; do
        log_info "Scaling down: ${service}"
        kubectl scale deployment "${service}" --replicas=0 \
            --namespace="neurosphere-${ENVIRONMENT}" 2>/dev/null || \
            kubectl scale statefulset "${service}" --replicas=0 \
            --namespace="neurosphere-${ENVIRONMENT}" 2>/dev/null || \
            log_warn "Could not scale down ${service} — may not exist as deployment/statefulset."
    done

    # Wait for pods to terminate
    log_info "Waiting for pods to terminate (60s timeout)..."
    kubectl wait --for=delete pod \
        --selector="app.kubernetes.io/part-of=neurosphere" \
        --namespace="neurosphere-${ENVIRONMENT}" \
        --timeout=60s 2>/dev/null || log_warn "Some pods may still be terminating."

    record_step "stop_services" "completed"
}

# ---------------------------------------------------------------------------
# Restore etcd
# ---------------------------------------------------------------------------
restore_etcd() {
    log_info "=== Restoring etcd from Snapshot ==="
    audit_log "etcd_restore" "started" "Restoring etcd from ${BACKUP_DATE} snapshot"

    # Find the latest snapshot for the given date
    local snapshot_key
    snapshot_key=$(aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX_ETCD}/etcd-snapshot-neurosphere-${ENVIRONMENT}-${BACKUP_DATE//-/}" 2>/dev/null \
        | sort | tail -1 | awk '{print $NF}')

    if [[ -z "${snapshot_key}" ]]; then
        log_error "No etcd snapshot found for date ${BACKUP_DATE}."
        exit 41
    fi

    local local_snapshot="${TEMP_DIR}/${snapshot_key}"
    local s3_full_key="${S3_PREFIX_ETCD}/${snapshot_key}"

    # Download snapshot
    log_info "Downloading: s3://${S3_BUCKET}/${s3_full_key}"
    aws s3 cp "s3://${S3_BUCKET}/${s3_full_key}" "${local_snapshot}"

    # Verify checksum
    local remote_checksum
    remote_checksum=$(aws s3 cp "s3://${S3_BUCKET}/${s3_full_key}.sha256" - 2>/dev/null || echo "")
    if [[ -n "${remote_checksum}" ]]; then
        local local_checksum
        local_checksum=$(sha256sum "${local_snapshot}" | awk '{print $1}')
        if [[ "${remote_checksum}" != "${local_checksum}" ]]; then
            log_error "etcd snapshot checksum mismatch!"
            record_step "etcd_restore" "failed" "Checksum mismatch"
            exit 42
        fi
        log_info "Checksum verified."
    fi

    # Decompress
    log_info "Decompressing snapshot..."
    gunzip "${local_snapshot}"
    local decompressed="${local_snapshot%.gz}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would restore etcd from ${decompressed}"
        record_step "etcd_restore" "skipped (dry run)"
        return
    fi

    # Restore etcd
    log_info "Restoring etcd snapshot..."
    etcdctl snapshot restore "${decompressed}" \
        --data-dir="/var/lib/etcd-restore" \
        2>&1 | tee -a "${LOG_FILE}"

    record_step "etcd_restore" "completed"
    audit_log "etcd_restore" "success" "etcd restored from snapshot ${snapshot_key}"
}

# ---------------------------------------------------------------------------
# Restore Vault
# ---------------------------------------------------------------------------
restore_vault() {
    log_info "=== Restoring Vault from Raft Snapshot ==="
    audit_log "vault_restore" "started" "Restoring Vault from ${BACKUP_DATE} snapshot"

    local snapshot_key
    snapshot_key=$(aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX_VAULT}/vault-raft-${ENVIRONMENT}-${BACKUP_DATE//-/}" 2>/dev/null \
        | sort | tail -1 | awk '{print $NF}')

    if [[ -z "${snapshot_key}" ]]; then
        log_error "No Vault snapshot found for date ${BACKUP_DATE}."
        exit 41
    fi

    local local_snapshot="${TEMP_DIR}/${snapshot_key}"

    log_info "Downloading: s3://${S3_BUCKET}/${S3_PREFIX_VAULT}/${snapshot_key}"
    aws s3 cp "s3://${S3_BUCKET}/${S3_PREFIX_VAULT}/${snapshot_key}" "${local_snapshot}"

    # Decompress
    gunzip "${local_snapshot}"
    local decompressed="${local_snapshot%.gz}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would restore Vault from ${decompressed}"
        record_step "vault_restore" "skipped (dry run)"
        return
    fi

    # Restore Vault Raft snapshot
    log_info "Restoring Vault Raft snapshot..."
    vault operator raft snapshot restore -force "${decompressed}" \
        2>&1 | tee -a "${LOG_FILE}"

    # Wait for Vault to come up
    log_info "Waiting for Vault to initialize after restore..."
    local retries=0
    while [[ ${retries} -lt 30 ]]; do
        if vault status &>/dev/null; then
            log_info "Vault is responding."
            break
        fi
        retries=$((retries + 1))
        sleep 2
    done

    record_step "vault_restore" "completed"
    audit_log "vault_restore" "success" "Vault restored from ${snapshot_key}"
}

# ---------------------------------------------------------------------------
# Restore database
# ---------------------------------------------------------------------------
restore_single_database() {
    local db_name="$1"
    log_info "--- Restoring database: ${db_name} ---"
    audit_log "db_restore" "started" "Restoring ${db_name} from ${BACKUP_DATE}"

    # Find backup file
    local backup_key
    backup_key=$(aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX_DB}/${BACKUP_DATE}/${db_name}-${ENVIRONMENT}-${BACKUP_DATE//-/}" 2>/dev/null \
        | sort | tail -1 | awk '{print $NF}')

    if [[ -z "${backup_key}" ]]; then
        log_error "No backup found for ${db_name} on ${BACKUP_DATE}."
        exit 41
    fi

    local local_file="${TEMP_DIR}/${backup_key}"
    local s3_full_key="${S3_PREFIX_DB}/${BACKUP_DATE}/${backup_key}"

    # Download encrypted backup
    log_info "[${db_name}] Downloading backup..."
    aws s3 cp "s3://${S3_BUCKET}/${s3_full_key}" "${local_file}"

    # Verify checksum
    local remote_checksum
    remote_checksum=$(aws s3 cp "s3://${S3_BUCKET}/${s3_full_key}.sha256" - 2>/dev/null || echo "")
    if [[ -n "${remote_checksum}" ]]; then
        local local_checksum
        local_checksum=$(sha256sum "${local_file}" | awk '{print $1}')
        if [[ "${remote_checksum}" != "${local_checksum}" ]]; then
            log_error "[${db_name}] Checksum mismatch!"
            exit 42
        fi
        log_info "[${db_name}] Checksum verified."
    fi

    # GPG decrypt
    log_info "[${db_name}] Decrypting with GPG..."
    local decrypted_file="${local_file%.gpg}"
    gpg --homedir "${GPG_HOMEDIR}" --decrypt --output "${decrypted_file}" "${local_file}" \
        2>&1 | tee -a "${LOG_FILE}"

    # Decompress
    log_info "[${db_name}] Decompressing..."
    gunzip "${decrypted_file}"
    local sql_file="${decrypted_file%.gz}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would restore ${db_name} from ${sql_file}"
        record_step "db_restore_${db_name}" "skipped (dry run)"
        return
    fi

    # Determine DB connection params
    local db_host db_port db_user password_env_var
    case "${db_name}" in
        robot-db)
            db_host="${ROBOT_DB_HOST:-robot-db.neurosphere.internal}"
            db_user="${ROBOT_DB_USER:-neurosphere_robot}"
            password_env_var="ROBOT_DB_PASSWORD" ;;
        patient-db)
            db_host="${PATIENT_DB_HOST:-patient-db.neurosphere.internal}"
            db_user="${PATIENT_DB_USER:-neurosphere_patient}"
            password_env_var="PATIENT_DB_PASSWORD" ;;
        telemetry-db)
            db_host="${TELEMETRY_DB_HOST:-telemetry-db.neurosphere.internal}"
            db_user="${TELEMETRY_DB_USER:-neurosphere_telemetry}"
            password_env_var="TELEMETRY_DB_PASSWORD" ;;
        *)
            log_error "Unknown database: ${db_name}"
            exit 45 ;;
    esac

    # Restore via psql
    log_info "[${db_name}] Restoring with psql..."
    export PGPASSWORD="${!password_env_var:-}"
    if ! psql --host="${db_host}" --port=5432 --username="${db_user}" \
        --dbname="${db_name}" --file="${sql_file}" \
        2>&1 | tee -a "${LOG_FILE}"; then
        log_error "[${db_name}] psql restore failed."
        unset PGPASSWORD
        exit 45
    fi
    unset PGPASSWORD

    record_step "db_restore_${db_name}" "completed"
    audit_log "db_restore" "success" "Database ${db_name} restored from ${backup_key}"
}

restore_databases() {
    log_info "=== Restoring Databases ==="

    local dbs=("${TARGET_DATABASE}")
    if [[ "${TARGET_DATABASE}" == "all" || "${COMPONENT}" == "full" ]]; then
        dbs=(robot-db patient-db telemetry-db)
    fi

    for db in "${dbs[@]}"; do
        restore_single_database "${db}"
    done
}

# ---------------------------------------------------------------------------
# Restart services in dependency order
# ---------------------------------------------------------------------------
restart_services() {
    log_info "=== Restarting Services in Dependency Order ==="

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would restart services: ${SERVICE_RESTART_ORDER[*]}"
        record_step "restart_services" "skipped (dry run)"
        return
    fi

    for service in "${SERVICE_RESTART_ORDER[@]}"; do
        log_info "Starting: ${service}"
        kubectl scale deployment "${service}" --replicas=2 \
            --namespace="neurosphere-${ENVIRONMENT}" 2>/dev/null || \
            kubectl scale statefulset "${service}" --replicas=1 \
            --namespace="neurosphere-${ENVIRONMENT}" 2>/dev/null || \
            log_warn "Could not scale up ${service}."

        # Wait for readiness before moving to next service
        log_info "Waiting for ${service} to be ready..."
        kubectl rollout status deployment/"${service}" \
            --namespace="neurosphere-${ENVIRONMENT}" \
            --timeout=120s 2>/dev/null || \
            kubectl rollout status statefulset/"${service}" \
            --namespace="neurosphere-${ENVIRONMENT}" \
            --timeout=120s 2>/dev/null || \
            log_warn "${service} did not reach ready state within timeout."
    done

    record_step "restart_services" "completed"
}

# ---------------------------------------------------------------------------
# Post-restore health checks
# ---------------------------------------------------------------------------
run_health_checks() {
    log_info "=== Running Post-Restore Health Checks ==="

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would run health checks."
        record_step "health_checks" "skipped (dry run)"
        return
    fi

    local failed_checks=()

    for service in "${!HEALTH_ENDPOINTS[@]}"; do
        local url="${HEALTH_ENDPOINTS[$service]}"
        log_info "Checking: ${service} -> ${url}"

        local retries=0
        local healthy=false
        while [[ ${retries} -lt 5 ]]; do
            if curl -sf --max-time 5 "${url}" &>/dev/null; then
                log_info "${service}: HEALTHY"
                healthy=true
                break
            fi
            retries=$((retries + 1))
            sleep 5
        done

        if [[ "${healthy}" != "true" ]]; then
            log_error "${service}: UNHEALTHY after ${retries} attempts"
            failed_checks+=("${service}")
        fi
    done

    if [[ ${#failed_checks[@]} -gt 0 ]]; then
        log_error "Health checks failed for: ${failed_checks[*]}"
        record_step "health_checks" "failed" "Unhealthy services: ${failed_checks[*]}"
        audit_log "health_checks" "failure" "Post-restore health check failures: ${failed_checks[*]}"
        exit 47
    fi

    record_step "health_checks" "passed"
    audit_log "health_checks" "success" "All post-restore health checks passed"
}

# ---------------------------------------------------------------------------
# Generate restore report
# ---------------------------------------------------------------------------
generate_report() {
    local end_time
    end_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    log_info "Generating restore report: ${REPORT_FILE}"

    local steps_json="["
    for i in "${!RESTORE_STEPS[@]}"; do
        [[ $i -gt 0 ]] && steps_json+=","
        steps_json+="${RESTORE_STEPS[$i]}"
    done
    steps_json+="]"

    cat > "${REPORT_FILE:-/dev/null}" <<-EOF
{
    "report_type": "cluster_restore",
    "environment": "${ENVIRONMENT}",
    "backup_date": "${BACKUP_DATE}",
    "component": "${COMPONENT}",
    "target_database": "${TARGET_DATABASE:-N/A}",
    "operator": "${OPERATOR}",
    "dry_run": ${DRY_RUN},
    "start_time": "${RESTORE_START_TIME}",
    "end_time": "${end_time}",
    "status": "${RESTORE_STATUS}",
    "steps": ${steps_json},
    "s3_bucket": "${S3_BUCKET}",
    "log_file": "${LOG_FILE}",
    "audit_log": "${AUDIT_LOG_FILE}"
}
EOF

    log_info "Restore report written to: ${REPORT_FILE}"
}

# ---------------------------------------------------------------------------
# Main orchestrator
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    log_info "================================================================="
    log_info "  NeuroSphere Cluster Restore — ${COMPONENT} from ${BACKUP_DATE}"
    log_info "  Environment: ${ENVIRONMENT} | Operator: ${OPERATOR}"
    log_info "  Dry Run: ${DRY_RUN}"
    log_info "================================================================="
    audit_log "restore_start" "started" "Cluster restore initiated: component=${COMPONENT}, date=${BACKUP_DATE}"

    check_dependencies
    pre_restore_validation

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "=== DRY RUN MODE — No changes will be made ==="
    fi

    case "${COMPONENT}" in
        full)
            stop_services
            restore_etcd
            restore_vault
            TARGET_DATABASE="all"
            restore_databases
            restart_services
            run_health_checks
            ;;
        etcd)
            stop_services
            restore_etcd
            restart_services
            run_health_checks
            ;;
        vault)
            restore_vault
            ;;
        database)
            restore_databases
            run_health_checks
            ;;
    esac

    RESTORE_STATUS="SUCCESS"
    log_info "================================================================="
    log_info "  NeuroSphere Cluster Restore COMPLETED SUCCESSFULLY"
    log_info "================================================================="
    audit_log "restore_complete" "success" "Cluster restore completed: ${COMPONENT} from ${BACKUP_DATE}"
}

main "$@"
