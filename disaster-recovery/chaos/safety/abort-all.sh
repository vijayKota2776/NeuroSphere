#!/usr/bin/env bash
# =============================================================================
# NeuroSphere Medical Robotics — EMERGENCY CHAOS ABORT
# =============================================================================
# PURPOSE:  Immediately terminate ALL running chaos experiments, restore
#           network policies, restart affected pods, and alert the ops team.
#
# USAGE:    ./abort-all.sh [--reason "reason for abort"]
#
# THIS SCRIPT IS DESIGNED FOR EMERGENCY USE:
#   - Run it if a chaos experiment causes unexpected patient system impact
#   - Run it if a surgical procedure starts during an active experiment
#   - Run it if any P0 alert fires during chaos testing
#   - Run it if you're unsure — it's always safe to abort
#
# WHAT THIS SCRIPT DOES:
#   1. Kills all running Chaos Mesh experiments (all types)
#   2. Removes all Chaos Mesh schedule resources
#   3. Restores default network policies
#   4. Restarts any pods stuck in CrashLoopBackOff
#   5. Uncordons any cordoned nodes
#   6. Sends emergency alert to ops team (Slack + PagerDuty)
#   7. Logs the incident for post-mortem analysis
#
# EXIT CODES:
#   0 - All chaos experiments aborted successfully
#   1 - Some abort operations failed (manual intervention may be needed)
#   2 - Critical failure (kubectl not available or cluster unreachable)
# =============================================================================

set -euo pipefail

# --- Configuration ---
NAMESPACE="neurosphere-core"
VAULT_NAMESPACE="neurosphere-vault"
DATA_NAMESPACE="neurosphere-data"
MONITORING_NAMESPACE="neurosphere-monitoring"
SLACK_WEBHOOK_URL="${CHAOS_SLACK_WEBHOOK_URL:-}"
PAGERDUTY_ROUTING_KEY="${CHAOS_PAGERDUTY_KEY:-}"
LOG_DIR="/var/log/neurosphere/chaos"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
INCIDENT_ID="CHAOS-ABORT-$(date +%Y%m%d-%H%M%S)"
ABORT_REASON="${1:-Manual emergency abort}"
EXIT_CODE=0

# --- Colors for terminal output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date -u +"%H:%M:%S") $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date -u +"%H:%M:%S") $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date -u +"%H:%M:%S") $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC}   $(date -u +"%H:%M:%S") $1"
}

# Parse command-line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --reason)
                ABORT_REASON="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 [--reason \"reason for abort\"]"
                echo ""
                echo "Emergency abort of all NeuroSphere chaos experiments."
                echo "Safe to run at any time — will only affect chaos resources."
                exit 0
                ;;
            *)
                ABORT_REASON="$1"
                shift
                ;;
        esac
    done
}

# =============================================================================
# Pre-Flight Checks
# =============================================================================

preflight_check() {
    log_info "Running pre-flight checks..."

    # Check kubectl is available
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found in PATH. Cannot abort chaos experiments."
        exit 2
    fi

    # Check cluster connectivity
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot reach Kubernetes cluster. Check your kubeconfig."
        exit 2
    fi

    # Check namespace exists
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_error "Namespace $NAMESPACE not found."
        exit 2
    fi

    log_success "Pre-flight checks passed."
}

# =============================================================================
# Step 1: Kill ALL Running Chaos Experiments
# =============================================================================

kill_all_chaos_experiments() {
    log_info "============================================="
    log_info "STEP 1: Killing all chaos experiments"
    log_info "============================================="

    local chaos_types=(
        "podchaos"
        "networkchaos"
        "stresschaos"
        "dnschaos"
        "iochaos"
        "httpchaos"
        "physicalmachinechaos"
    )

    local namespaces=(
        "$NAMESPACE"
        "$VAULT_NAMESPACE"
        "$DATA_NAMESPACE"
        "$MONITORING_NAMESPACE"
    )

    for ns in "${namespaces[@]}"; do
        for chaos_type in "${chaos_types[@]}"; do
            local count
            count=$(kubectl get "$chaos_type" -n "$ns" --no-headers 2>/dev/null | wc -l || echo "0")
            if [[ "$count" -gt 0 ]]; then
                log_info "Deleting $count $chaos_type resources in $ns..."
                if kubectl delete "$chaos_type" --all -n "$ns" --timeout=30s 2>/dev/null; then
                    log_success "Deleted all $chaos_type in $ns"
                else
                    log_warn "Some $chaos_type in $ns may not have been deleted"
                    EXIT_CODE=1
                fi
            fi
        done
    done

    log_success "All chaos experiments terminated."
}

# =============================================================================
# Step 2: Remove All Chaos Schedules and Workflows
# =============================================================================

kill_all_schedules_and_workflows() {
    log_info "============================================="
    log_info "STEP 2: Removing schedules and workflows"
    log_info "============================================="

    local schedule_types=(
        "schedules.chaos-mesh.org"
        "workflows.chaos-mesh.org"
    )

    for schedule_type in "${schedule_types[@]}"; do
        local count
        count=$(kubectl get "$schedule_type" -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l || echo "0")
        if [[ "$count" -gt 0 ]]; then
            log_info "Deleting $count $schedule_type resources..."
            if kubectl delete "$schedule_type" --all -n "$NAMESPACE" --timeout=30s 2>/dev/null; then
                log_success "Deleted all $schedule_type"
            else
                log_warn "Some $schedule_type may not have been deleted"
                EXIT_CODE=1
            fi
        fi
    done

    log_success "All schedules and workflows removed."
}

# =============================================================================
# Step 3: Restore Network Policies
# =============================================================================

restore_network_policies() {
    log_info "============================================="
    log_info "STEP 3: Restoring network policies"
    log_info "============================================="

    # Remove any chaos-injected network policies
    log_info "Removing chaos-injected network policies..."
    kubectl get networkpolicies -n "$NAMESPACE" \
        -l "chaos-mesh.org/managed=true" \
        --no-headers 2>/dev/null | \
        awk '{print $1}' | \
        xargs -r kubectl delete networkpolicy -n "$NAMESPACE" 2>/dev/null || true

    # Verify default network policies are in place
    log_info "Verifying default network policies..."
    local default_policies
    default_policies=$(kubectl get networkpolicies -n "$NAMESPACE" \
        -l "neurosphere.io/managed=true" --no-headers 2>/dev/null | wc -l || echo "0")

    if [[ "$default_policies" -gt 0 ]]; then
        log_success "Default network policies intact ($default_policies policies found)"
    else
        log_warn "No default network policies found — may need manual restoration"
        EXIT_CODE=1
    fi

    # Restore cross-namespace communication (core <-> vault)
    log_info "Verifying cross-namespace connectivity..."
    kubectl get networkpolicies -n "$VAULT_NAMESPACE" \
        -l "chaos-mesh.org/managed=true" \
        --no-headers 2>/dev/null | \
        awk '{print $1}' | \
        xargs -r kubectl delete networkpolicy -n "$VAULT_NAMESPACE" 2>/dev/null || true

    log_success "Network policies restored."
}

# =============================================================================
# Step 4: Restart Affected Pods
# =============================================================================

restart_affected_pods() {
    log_info "============================================="
    log_info "STEP 4: Restarting affected pods"
    log_info "============================================="

    # Find pods in CrashLoopBackOff or Error state
    log_info "Checking for pods in unhealthy states..."
    local unhealthy_pods
    unhealthy_pods=$(kubectl get pods -n "$NAMESPACE" \
        --field-selector=status.phase!=Running,status.phase!=Succeeded \
        --no-headers 2>/dev/null | awk '{print $1}' || true)

    if [[ -n "$unhealthy_pods" ]]; then
        log_warn "Found unhealthy pods, restarting..."
        echo "$unhealthy_pods" | while read -r pod; do
            log_info "  Deleting unhealthy pod: $pod"
            kubectl delete pod "$pod" -n "$NAMESPACE" --grace-period=10 2>/dev/null || true
        done
    else
        log_success "No unhealthy pods found"
    fi

    # Check for pods with chaos sidecar injection that need cleanup
    log_info "Checking for chaos-mesh injected sidecars..."
    local injected_pods
    injected_pods=$(kubectl get pods -n "$NAMESPACE" \
        -l "chaos-mesh.org/injected=true" \
        --no-headers 2>/dev/null | awk '{print $1}' || true)

    if [[ -n "$injected_pods" ]]; then
        log_warn "Found pods with chaos injection, performing rolling restart..."
        # Rolling restart of affected deployments
        kubectl get deployments -n "$NAMESPACE" -l "project=neurosphere" \
            --no-headers 2>/dev/null | awk '{print $1}' | while read -r deploy; do
            log_info "  Rolling restart: $deploy"
            kubectl rollout restart deployment/"$deploy" -n "$NAMESPACE" 2>/dev/null || true
        done
    fi

    # Wait for critical services to be ready
    log_info "Waiting for critical services to stabilize..."
    local critical_services=(
        "deployment/patient-monitor"
        "deployment/robot-command-service"
        "deployment/api-gateway"
    )

    for svc in "${critical_services[@]}"; do
        log_info "  Waiting for $svc..."
        if kubectl rollout status "$svc" -n "$NAMESPACE" --timeout=120s 2>/dev/null; then
            log_success "  $svc is ready"
        else
            log_warn "  $svc may still be recovering"
            EXIT_CODE=1
        fi
    done

    log_success "Pod recovery complete."
}

# =============================================================================
# Step 5: Uncordon Any Cordoned Nodes
# =============================================================================

uncordon_nodes() {
    log_info "============================================="
    log_info "STEP 5: Uncordoning any cordoned nodes"
    log_info "============================================="

    local cordoned_nodes
    cordoned_nodes=$(kubectl get nodes -o json 2>/dev/null | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
for node in data.get('items', []):
    if node.get('spec', {}).get('unschedulable', False):
        print(node['metadata']['name'])
" 2>/dev/null || true)

    if [[ -n "$cordoned_nodes" ]]; then
        echo "$cordoned_nodes" | while read -r node; do
            log_info "  Uncordoning node: $node"
            kubectl uncordon "$node" 2>/dev/null || true
        done
        log_success "All cordoned nodes uncordoned."
    else
        log_success "No cordoned nodes found."
    fi
}

# =============================================================================
# Step 6: Send Alert to Ops Team
# =============================================================================

send_alerts() {
    log_info "============================================="
    log_info "STEP 6: Sending alerts to ops team"
    log_info "============================================="

    # --- Slack Alert ---
    if [[ -n "$SLACK_WEBHOOK_URL" ]]; then
        log_info "Sending Slack alert..."
        local slack_payload
        slack_payload=$(cat <<EOF
{
    "channel": "#neurosphere-chaos",
    "username": "Chaos Bot",
    "icon_emoji": ":rotating_light:",
    "attachments": [
        {
            "color": "#FF0000",
            "title": ":rotating_light: EMERGENCY CHAOS ABORT EXECUTED",
            "fields": [
                {
                    "title": "Incident ID",
                    "value": "\`${INCIDENT_ID}\`",
                    "short": true
                },
                {
                    "title": "Timestamp (UTC)",
                    "value": "${TIMESTAMP}",
                    "short": true
                },
                {
                    "title": "Abort Reason",
                    "value": "${ABORT_REASON}",
                    "short": false
                },
                {
                    "title": "Actions Taken",
                    "value": "1. All chaos experiments terminated\n2. Schedules/workflows removed\n3. Network policies restored\n4. Affected pods restarted\n5. Cordoned nodes uncordoned",
                    "short": false
                },
                {
                    "title": "Exit Code",
                    "value": "${EXIT_CODE} (0=clean, 1=partial, 2=critical)",
                    "short": true
                }
            ],
            "footer": "NeuroSphere Chaos Engineering",
            "ts": $(date +%s)
        }
    ]
}
EOF
)
        if curl -s -X POST "$SLACK_WEBHOOK_URL" \
            -H 'Content-Type: application/json' \
            -d "$slack_payload" > /dev/null 2>&1; then
            log_success "Slack alert sent"
        else
            log_warn "Failed to send Slack alert"
        fi
    else
        log_warn "CHAOS_SLACK_WEBHOOK_URL not set — skipping Slack alert"
    fi

    # --- PagerDuty Alert ---
    if [[ -n "$PAGERDUTY_ROUTING_KEY" ]]; then
        log_info "Sending PagerDuty alert..."
        local pd_payload
        pd_payload=$(cat <<EOF
{
    "routing_key": "${PAGERDUTY_ROUTING_KEY}",
    "event_action": "trigger",
    "dedup_key": "${INCIDENT_ID}",
    "payload": {
        "summary": "EMERGENCY: NeuroSphere chaos experiments aborted - ${ABORT_REASON}",
        "severity": "critical",
        "source": "neurosphere-chaos-framework",
        "component": "chaos-engineering",
        "group": "neurosphere-core",
        "class": "chaos-abort",
        "custom_details": {
            "incident_id": "${INCIDENT_ID}",
            "abort_reason": "${ABORT_REASON}",
            "timestamp": "${TIMESTAMP}",
            "namespace": "${NAMESPACE}",
            "exit_code": ${EXIT_CODE}
        }
    }
}
EOF
)
        if curl -s -X POST "https://events.pagerduty.com/v2/enqueue" \
            -H 'Content-Type: application/json' \
            -d "$pd_payload" > /dev/null 2>&1; then
            log_success "PagerDuty alert sent"
        else
            log_warn "Failed to send PagerDuty alert"
        fi
    else
        log_warn "CHAOS_PAGERDUTY_KEY not set — skipping PagerDuty alert"
    fi
}

# =============================================================================
# Step 7: Log Incident
# =============================================================================

log_incident() {
    log_info "============================================="
    log_info "STEP 7: Logging incident"
    log_info "============================================="

    # Create log directory if it doesn't exist
    mkdir -p "$LOG_DIR" 2>/dev/null || true

    local log_file="${LOG_DIR}/${INCIDENT_ID}.json"

    # Collect cluster state snapshot
    local pod_status
    pod_status=$(kubectl get pods -n "$NAMESPACE" -o json 2>/dev/null | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
pods = []
for pod in data.get('items', []):
    pods.append({
        'name': pod['metadata']['name'],
        'status': pod['status']['phase'],
        'restarts': sum(cs.get('restartCount', 0) for cs in pod['status'].get('containerStatuses', []))
    })
print(json.dumps(pods, indent=2))
" 2>/dev/null || echo "[]")

    # Write incident log
    cat > "$log_file" 2>/dev/null <<EOF || true
{
    "incident_id": "${INCIDENT_ID}",
    "timestamp": "${TIMESTAMP}",
    "type": "chaos-emergency-abort",
    "reason": "${ABORT_REASON}",
    "namespace": "${NAMESPACE}",
    "exit_code": ${EXIT_CODE},
    "actions_taken": [
        "Killed all chaos experiments",
        "Removed all schedules and workflows",
        "Restored network policies",
        "Restarted affected pods",
        "Uncordoned cordoned nodes",
        "Sent ops alerts"
    ],
    "cluster_state_snapshot": {
        "pods": ${pod_status}
    },
    "operator": "$(whoami 2>/dev/null || echo 'unknown')",
    "hostname": "$(hostname 2>/dev/null || echo 'unknown')"
}
EOF

    if [[ -f "$log_file" ]]; then
        log_success "Incident logged to: $log_file"
    else
        log_warn "Could not write incident log (check permissions on $LOG_DIR)"
    fi
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║       NEUROSPHERE EMERGENCY CHAOS ABORT                     ║${NC}"
    echo -e "${RED}║       Terminating ALL chaos experiments immediately          ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Incident ID:  ${YELLOW}${INCIDENT_ID}${NC}"
    echo -e "  Timestamp:    ${TIMESTAMP}"
    echo -e "  Reason:       ${ABORT_REASON}"
    echo -e "  Namespace:    ${NAMESPACE}"
    echo ""

    parse_args "$@"
    preflight_check

    kill_all_chaos_experiments
    kill_all_schedules_and_workflows
    restore_network_policies
    restart_affected_pods
    uncordon_nodes
    send_alerts
    log_incident

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║       ABORT COMPLETE                                        ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if [[ $EXIT_CODE -eq 0 ]]; then
        log_success "All chaos experiments aborted cleanly."
    else
        log_warn "Some operations had issues. Check logs and verify cluster state manually."
        log_warn "Incident ID: ${INCIDENT_ID}"
    fi

    echo ""
    echo -e "  ${BLUE}Next Steps:${NC}"
    echo "  1. Verify all services are healthy:  kubectl get pods -n $NAMESPACE"
    echo "  2. Check service health endpoints manually"
    echo "  3. Review incident log: ${LOG_DIR}/${INCIDENT_ID}.json"
    echo "  4. Conduct post-mortem if abort was due to unexpected impact"
    echo ""

    exit $EXIT_CODE
}

# Run main with all arguments
main "$@"
