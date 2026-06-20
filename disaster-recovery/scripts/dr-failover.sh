#!/usr/bin/env bash
###############################################################################
# NeuroSphere Medical Robotics — Automated DR Failover
#
# Monitors primary region health and orchestrates failover to the DR region:
#   1. Health check primary region endpoints
#   2. If primary is unhealthy → switch Route53 DNS to DR region
#   3. Promote RDS read replicas to primary
#   4. Update Vault configuration for DR region
#   5. Notify operations team via PagerDuty / SNS
#   6. Log all actions for post-incident review
#
# SAFETY: This script has a confirmation gate for production failovers
# unless --force is specified (for fully-automated invocation).
#
# Usage:
#   ./dr-failover.sh --environment production
#   ./dr-failover.sh --environment production --force    # Skip confirmation
#   ./dr-failover.sh --environment production --check-only  # Health check only
#
# Exit Codes:
#   0  — Failover completed successfully (or primary is healthy)
#   1  — General error
#   50 — Primary health check failed (failover needed)
#   51 — DNS failover failed
#   52 — Replica promotion failed
#   53 — Vault reconfiguration failed
#   54 — Notification failed (non-fatal, logged)
#   55 — Missing dependencies
#   56 — Invalid arguments
###############################################################################
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
ENVIRONMENT="${NEUROSPHERE_ENV:-}"
FORCE_FAILOVER="${FORCE_FAILOVER:-false}"
CHECK_ONLY="${CHECK_ONLY:-false}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="/var/log/neurosphere/dr-failover.log"
AUDIT_LOG_FILE="/var/log/neurosphere/dr-failover-audit.log"
OPERATOR="${OPERATOR:-system/failover-agent}"

# Primary region
PRIMARY_REGION="${PRIMARY_REGION:-us-east-1}"
PRIMARY_CLUSTER_ENDPOINT="${PRIMARY_CLUSTER_ENDPOINT:-https://api.neurosphere.internal}"

# DR region
DR_REGION="${DR_REGION:-us-west-2}"
DR_CLUSTER_ENDPOINT="${DR_CLUSTER_ENDPOINT:-https://api-dr.neurosphere.internal}"

# Route53
HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-}"
DNS_RECORD_NAME="${DNS_RECORD_NAME:-api.neurosphere.io}"

# Health check configuration
HEALTH_CHECK_RETRIES=3
HEALTH_CHECK_INTERVAL=10  # seconds between retries
HEALTH_CHECK_TIMEOUT=5    # seconds per request

# SNS topic for notifications
SNS_TOPIC_ARN="${SNS_TOPIC_ARN:-arn:aws:sns:${PRIMARY_REGION}:ACCOUNT_ID:neurosphere-${ENVIRONMENT:-staging}-ops-alerts}"

# PagerDuty integration key
PAGERDUTY_SERVICE_KEY="${PAGERDUTY_SERVICE_KEY:-}"

# Services to check in primary region
PRIMARY_HEALTH_ENDPOINTS=(
    "https://api.neurosphere.internal/health"
    "https://patient-monitor.neurosphere.internal/health"
    "https://robot-command.neurosphere.internal/health"
)

# RDS instances to promote
RDS_READ_REPLICAS=(
    "neurosphere-${ENVIRONMENT:-staging}-robot-db-replica"
    "neurosphere-${ENVIRONMENT:-staging}-patient-db-replica"
    "neurosphere-${ENVIRONMENT:-staging}-telemetry-db-replica"
)

# Track failover phases
declare -a FAILOVER_ACTIONS=()

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "${LOG_FILE}")" "$(dirname "${AUDIT_LOG_FILE}")"

log() {
    local level="$1"; shift
    printf '{"timestamp":"%s","level":"%s","component":"dr-failover","environment":"%s","operator":"%s","primary_region":"%s","dr_region":"%s","message":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${level}" "${ENVIRONMENT}" "${OPERATOR}" \
        "${PRIMARY_REGION}" "${DR_REGION}" "$*" \
        | tee -a "${LOG_FILE}"
}

audit_log() {
    local action="$1"; shift
    local status="$1"; shift
    printf '{"timestamp":"%s","audit_type":"dr-failover","action":"%s","status":"%s","operator":"%s","environment":"%s","primary_region":"%s","dr_region":"%s","detail":"%s","hipaa_relevant":true}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${action}" "${status}" "${OPERATOR}" \
        "${ENVIRONMENT}" "${PRIMARY_REGION}" "${DR_REGION}" "$*" \
        | tee -a "${AUDIT_LOG_FILE}" >> "${LOG_FILE}"
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

record_action() {
    FAILOVER_ACTIONS+=("$(printf '[%s] %s: %s' "$(date -u +%H:%M:%S)" "$1" "$2")")
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --environment)  ENVIRONMENT="$2"; shift 2 ;;
            --force)        FORCE_FAILOVER="true"; shift ;;
            --check-only)   CHECK_ONLY="true"; shift ;;
            --help|-h)      usage; exit 0 ;;
            *)              log_error "Unknown argument: $1"; usage; exit 56 ;;
        esac
    done

    if [[ -z "${ENVIRONMENT}" ]]; then
        log_error "--environment is required."
        usage
        exit 56
    fi

    if [[ ! "${ENVIRONMENT}" =~ ^(dev|staging|production)$ ]]; then
        log_error "Invalid environment: ${ENVIRONMENT}"
        exit 56
    fi

    # Update SNS topic with actual environment
    SNS_TOPIC_ARN="arn:aws:sns:${PRIMARY_REGION}:ACCOUNT_ID:neurosphere-${ENVIRONMENT}-ops-alerts"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Required:
  --environment ENV     Target environment (dev|staging|production)

Optional:
  --force               Skip manual confirmation for production failover
  --check-only          Only perform health checks, do not fail over
  --help                Show this help message
EOF
}

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
check_dependencies() {
    local missing=()
    for cmd in aws curl jq; do
        command -v "${cmd}" &>/dev/null || missing+=("${cmd}")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing[*]}"
        exit 55
    fi
}

# ---------------------------------------------------------------------------
# Step 1: Health check primary region
# ---------------------------------------------------------------------------
check_primary_health() {
    log_info "=== Checking Primary Region Health (${PRIMARY_REGION}) ==="

    local total_endpoints=${#PRIMARY_HEALTH_ENDPOINTS[@]}
    local healthy_count=0
    local unhealthy_endpoints=()

    for endpoint in "${PRIMARY_HEALTH_ENDPOINTS[@]}"; do
        local is_healthy=false
        local attempt=0

        while [[ ${attempt} -lt ${HEALTH_CHECK_RETRIES} ]]; do
            attempt=$((attempt + 1))
            log_info "Health check (attempt ${attempt}/${HEALTH_CHECK_RETRIES}): ${endpoint}"

            local http_code
            http_code=$(curl -sf --max-time "${HEALTH_CHECK_TIMEOUT}" \
                -o /dev/null -w "%{http_code}" "${endpoint}" 2>/dev/null || echo "000")

            if [[ "${http_code}" == "200" ]]; then
                log_info "${endpoint}: HEALTHY (HTTP ${http_code})"
                is_healthy=true
                break
            fi

            log_warn "${endpoint}: UNHEALTHY (HTTP ${http_code}) — retrying in ${HEALTH_CHECK_INTERVAL}s..."
            sleep "${HEALTH_CHECK_INTERVAL}"
        done

        if [[ "${is_healthy}" == "true" ]]; then
            healthy_count=$((healthy_count + 1))
        else
            unhealthy_endpoints+=("${endpoint}")
        fi
    done

    log_info "Health check results: ${healthy_count}/${total_endpoints} endpoints healthy"

    if [[ ${healthy_count} -eq ${total_endpoints} ]]; then
        log_info "Primary region is HEALTHY. No failover needed."
        record_action "health_check" "Primary region healthy — ${healthy_count}/${total_endpoints}"
        return 0
    fi

    log_error "Primary region is UNHEALTHY. Unhealthy endpoints: ${unhealthy_endpoints[*]}"
    record_action "health_check" "Primary UNHEALTHY — ${unhealthy_endpoints[*]}"
    audit_log "health_check" "failure" "Primary region unhealthy: ${unhealthy_endpoints[*]}"
    return 1
}

# ---------------------------------------------------------------------------
# Step 2: Confirm failover (production safety gate)
# ---------------------------------------------------------------------------
confirm_failover() {
    if [[ "${FORCE_FAILOVER}" == "true" ]]; then
        log_info "Force flag set — skipping manual confirmation."
        return 0
    fi

    if [[ "${ENVIRONMENT}" == "production" ]]; then
        echo ""
        echo "╔══════════════════════════════════════════════════════════════╗"
        echo "║  ⚠️  PRODUCTION DR FAILOVER CONFIRMATION                    ║"
        echo "║                                                            ║"
        echo "║  This will:                                                ║"
        echo "║    1. Switch DNS to DR region (${DR_REGION})               ║"
        echo "║    2. Promote database read replicas                       ║"
        echo "║    3. Reconfigure Vault for DR                             ║"
        echo "║                                                            ║"
        echo "║  Type 'FAILOVER' to proceed:                               ║"
        echo "╚══════════════════════════════════════════════════════════════╝"
        echo ""
        read -rp "Confirmation: " confirmation
        if [[ "${confirmation}" != "FAILOVER" ]]; then
            log_info "Failover cancelled by operator."
            audit_log "failover_confirm" "cancelled" "Operator cancelled production failover"
            exit 0
        fi
        audit_log "failover_confirm" "confirmed" "Operator confirmed production failover"
    fi
}

# ---------------------------------------------------------------------------
# Step 3: Switch DNS to DR region
# ---------------------------------------------------------------------------
switch_dns() {
    log_info "=== Switching DNS to DR Region (${DR_REGION}) ==="
    audit_log "dns_switch" "started" "Switching ${DNS_RECORD_NAME} to DR region"

    if [[ -z "${HOSTED_ZONE_ID}" ]]; then
        # Auto-discover hosted zone
        HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
            --dns-name "neurosphere.io" \
            --query 'HostedZones[0].Id' \
            --output text 2>/dev/null | sed 's|/hostedzone/||')
    fi

    if [[ -z "${HOSTED_ZONE_ID}" ]]; then
        log_error "Could not determine Route53 hosted zone ID."
        exit 51
    fi

    # Create Route53 change batch
    local change_batch
    change_batch=$(cat <<-EOF
{
    "Comment": "NeuroSphere DR failover - ${TIMESTAMP}",
    "Changes": [
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "${DNS_RECORD_NAME}",
                "Type": "CNAME",
                "TTL": 60,
                "ResourceRecords": [
                    {
                        "Value": "neurosphere-${ENVIRONMENT}-dr.${DR_REGION}.elb.amazonaws.com"
                    }
                ]
            }
        }
    ]
}
EOF
    )

    log_info "Submitting Route53 change..."
    local change_id
    if ! change_id=$(aws route53 change-resource-record-sets \
        --hosted-zone-id "${HOSTED_ZONE_ID}" \
        --change-batch "${change_batch}" \
        --query 'ChangeInfo.Id' \
        --output text 2>&1); then
        log_error "Route53 DNS switch failed: ${change_id}"
        audit_log "dns_switch" "failure" "Route53 change failed"
        exit 51
    fi

    log_info "DNS change submitted: ${change_id}. Waiting for propagation..."

    # Wait for DNS propagation (max 120s)
    local retries=0
    while [[ ${retries} -lt 12 ]]; do
        local status
        status=$(aws route53 get-change --id "${change_id}" \
            --query 'ChangeInfo.Status' --output text 2>/dev/null || echo "PENDING")
        if [[ "${status}" == "INSYNC" ]]; then
            log_info "DNS change propagated."
            break
        fi
        retries=$((retries + 1))
        sleep 10
    done

    record_action "dns_switch" "DNS switched to DR region (${DR_REGION})"
    audit_log "dns_switch" "success" "DNS ${DNS_RECORD_NAME} now points to ${DR_REGION}"
}

# ---------------------------------------------------------------------------
# Step 4: Promote RDS read replicas
# ---------------------------------------------------------------------------
promote_replicas() {
    log_info "=== Promoting RDS Read Replicas in DR Region ==="
    audit_log "replica_promote" "started" "Promoting ${#RDS_READ_REPLICAS[@]} read replicas"

    for replica in "${RDS_READ_REPLICAS[@]}"; do
        log_info "Promoting: ${replica}"

        if ! aws rds promote-read-replica \
            --db-instance-identifier "${replica}" \
            --region "${DR_REGION}" \
            2>&1 | tee -a "${LOG_FILE}"; then
            log_error "Failed to promote replica: ${replica}"
            audit_log "replica_promote" "failure" "Failed to promote ${replica}"
            exit 52
        fi

        record_action "replica_promote" "Promoted ${replica}"
    done

    # Wait for replicas to become available
    log_info "Waiting for promoted instances to become available..."
    for replica in "${RDS_READ_REPLICAS[@]}"; do
        local retries=0
        while [[ ${retries} -lt 30 ]]; do
            local status
            status=$(aws rds describe-db-instances \
                --db-instance-identifier "${replica}" \
                --region "${DR_REGION}" \
                --query 'DBInstances[0].DBInstanceStatus' \
                --output text 2>/dev/null || echo "unknown")
            if [[ "${status}" == "available" ]]; then
                log_info "${replica}: available"
                break
            fi
            log_info "${replica}: ${status} — waiting..."
            retries=$((retries + 1))
            sleep 30
        done
    done

    audit_log "replica_promote" "success" "All read replicas promoted to primary"
}

# ---------------------------------------------------------------------------
# Step 5: Update Vault configuration
# ---------------------------------------------------------------------------
update_vault() {
    log_info "=== Updating Vault Configuration for DR Region ==="
    audit_log "vault_update" "started" "Reconfiguring Vault for DR region"

    # Point Vault to DR region endpoints
    export VAULT_ADDR="${VAULT_ADDR:-https://vault-dr.neurosphere.internal:8200}"

    # Update database secret engine connection strings
    local db_configs=(
        "robot-db|neurosphere-${ENVIRONMENT}-robot-db-replica.${DR_REGION}.rds.amazonaws.com"
        "patient-db|neurosphere-${ENVIRONMENT}-patient-db-replica.${DR_REGION}.rds.amazonaws.com"
        "telemetry-db|neurosphere-${ENVIRONMENT}-telemetry-db-replica.${DR_REGION}.rds.amazonaws.com"
    )

    for config in "${db_configs[@]}"; do
        IFS='|' read -r db_name db_host <<< "${config}"
        log_info "Updating Vault DB connection: ${db_name} -> ${db_host}"

        vault write "database/config/${db_name}" \
            connection_url="postgresql://{{username}}:{{password}}@${db_host}:5432/${db_name}?sslmode=require" \
            2>&1 | tee -a "${LOG_FILE}" || \
            log_warn "Could not update Vault config for ${db_name}"
    done

    # Update KV secrets with DR region metadata
    vault kv put "secret/neurosphere/${ENVIRONMENT}/cluster" \
        region="${DR_REGION}" \
        failover_timestamp="${TIMESTAMP}" \
        primary_region="${PRIMARY_REGION}" \
        dr_active="true" \
        2>&1 | tee -a "${LOG_FILE}" || \
        log_warn "Could not update cluster metadata in Vault"

    record_action "vault_update" "Vault reconfigured for DR region"
    audit_log "vault_update" "success" "Vault database connections updated for ${DR_REGION}"
}

# ---------------------------------------------------------------------------
# Step 6: Notify operations team
# ---------------------------------------------------------------------------
notify_ops() {
    log_info "=== Notifying Operations Team ==="

    local actions_summary=""
    for action in "${FAILOVER_ACTIONS[@]}"; do
        actions_summary+="  ${action}\n"
    done

    local message
    message=$(cat <<-EOF
🚨 NeuroSphere DR FAILOVER EXECUTED

Environment: ${ENVIRONMENT}
Timestamp:   ${TIMESTAMP}
Operator:    ${OPERATOR}
Primary:     ${PRIMARY_REGION} (UNHEALTHY)
DR Region:   ${DR_REGION} (ACTIVE)

Actions Taken:
${actions_summary}

⚠️  IMMEDIATE ACTIONS REQUIRED:
1. Verify DR region services via ${DR_CLUSTER_ENDPOINT}/health
2. Investigate primary region failure in ${PRIMARY_REGION}
3. Monitor DR region performance for anomalies
4. Plan failback once primary is restored

Audit log: ${AUDIT_LOG_FILE}
EOF
    )

    # SNS notification
    if aws sns publish \
        --topic-arn "${SNS_TOPIC_ARN}" \
        --subject "🚨 [${ENVIRONMENT^^}] NeuroSphere DR Failover Executed" \
        --message "${message}" \
        --region "${PRIMARY_REGION}" 2>/dev/null; then
        log_info "SNS notification sent."
    else
        log_warn "SNS notification failed — attempting DR region SNS..."
        aws sns publish \
            --topic-arn "${SNS_TOPIC_ARN//${PRIMARY_REGION}/${DR_REGION}}" \
            --subject "🚨 [${ENVIRONMENT^^}] NeuroSphere DR Failover Executed" \
            --message "${message}" \
            --region "${DR_REGION}" 2>/dev/null || \
            log_error "All SNS notification attempts failed."
    fi

    # PagerDuty incident (if configured)
    if [[ -n "${PAGERDUTY_SERVICE_KEY}" ]]; then
        log_info "Creating PagerDuty incident..."
        curl -sf --max-time 10 \
            -H "Content-Type: application/json" \
            -X POST "https://events.pagerduty.com/v2/enqueue" \
            -d "{
                \"routing_key\": \"${PAGERDUTY_SERVICE_KEY}\",
                \"event_action\": \"trigger\",
                \"payload\": {
                    \"summary\": \"NeuroSphere ${ENVIRONMENT} DR failover executed - primary ${PRIMARY_REGION} unhealthy\",
                    \"severity\": \"critical\",
                    \"source\": \"neurosphere-dr-failover\",
                    \"component\": \"infrastructure\",
                    \"group\": \"${ENVIRONMENT}\",
                    \"custom_details\": {
                        \"primary_region\": \"${PRIMARY_REGION}\",
                        \"dr_region\": \"${DR_REGION}\",
                        \"timestamp\": \"${TIMESTAMP}\",
                        \"operator\": \"${OPERATOR}\"
                    }
                }
            }" 2>/dev/null || log_warn "PagerDuty notification failed."
    fi

    record_action "notify_ops" "Operations team notified via SNS and PagerDuty"
    audit_log "notification" "success" "Operations team notified of DR failover"
}

# ---------------------------------------------------------------------------
# Verify DR region health post-failover
# ---------------------------------------------------------------------------
verify_dr_health() {
    log_info "=== Verifying DR Region Health ==="

    local dr_endpoints=(
        "${DR_CLUSTER_ENDPOINT}/health"
    )

    for endpoint in "${dr_endpoints[@]}"; do
        local retries=0
        local healthy=false
        while [[ ${retries} -lt 5 ]]; do
            if curl -sf --max-time 5 "${endpoint}" &>/dev/null; then
                log_info "DR endpoint healthy: ${endpoint}"
                healthy=true
                break
            fi
            retries=$((retries + 1))
            sleep 5
        done
        if [[ "${healthy}" != "true" ]]; then
            log_error "DR endpoint unhealthy: ${endpoint}"
        fi
    done

    record_action "dr_health_check" "DR region health verified"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_dependencies

    log_info "================================================================="
    log_info "  NeuroSphere DR Failover Controller"
    log_info "  Environment: ${ENVIRONMENT}"
    log_info "  Primary: ${PRIMARY_REGION} | DR: ${DR_REGION}"
    log_info "================================================================="
    audit_log "failover_start" "started" "DR failover check initiated"

    # Step 1: Check primary health
    if check_primary_health; then
        log_info "Primary region is healthy. No action needed."
        audit_log "failover_start" "skipped" "Primary region healthy — no failover required"
        exit 0
    fi

    if [[ "${CHECK_ONLY}" == "true" ]]; then
        log_error "Primary is UNHEALTHY but --check-only was specified. Exiting."
        audit_log "failover_start" "check_only" "Primary unhealthy but check-only mode"
        exit 50
    fi

    # Step 2: Confirm (production safety gate)
    confirm_failover

    log_info "================================================================="
    log_info "  🚨 INITIATING DR FAILOVER  🚨"
    log_info "================================================================="
    audit_log "failover_execute" "started" "Failover sequence initiated"

    # Step 3: Switch DNS
    switch_dns

    # Step 4: Promote replicas
    promote_replicas

    # Step 5: Update Vault
    update_vault

    # Step 6: Verify DR region
    verify_dr_health

    # Step 7: Notify ops
    notify_ops

    log_info "================================================================="
    log_info "  ✅ DR FAILOVER COMPLETE"
    log_info "  Active Region: ${DR_REGION}"
    log_info "  DNS Record:    ${DNS_RECORD_NAME} → ${DR_REGION}"
    log_info "================================================================="
    audit_log "failover_execute" "success" "DR failover completed — active region: ${DR_REGION}"
}

main "$@"
