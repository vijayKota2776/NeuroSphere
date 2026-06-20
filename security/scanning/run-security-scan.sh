#!/bin/bash
# =============================================================================
# NeuroSphere Comprehensive Security Scanner
# =============================================================================
# Purpose:  Orchestrate all security scanning tools across NeuroSphere
#           microservices and produce consolidated reports.
# Tools:    Trivy (container/IaC), Bandit (Python SAST), npm audit (Node.js),
#           OWASP Dependency-Check (SCA)
# Output:   JSON + HTML reports in the specified output directory
# Exit:     0 = clean, 1 = warnings (MEDIUM), 2 = critical (HIGH/CRITICAL)
# Standard: FDA Cybersecurity Guidance, IEC 62443-4-1, HIPAA §164.312
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TRIVY_CONFIG="${SCRIPT_DIR}/trivy.yaml"
BANDIT_CONFIG="${SCRIPT_DIR}/.bandit.yml"
OWASP_SUPPRESSION="${SCRIPT_DIR}/owasp-dc-suppression.xml"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
MAX_EXIT_CODE=0

# ANSI colors for terminal output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Default Configuration
# ---------------------------------------------------------------------------
SERVICE=""                     # Empty = scan all services
SEVERITY_THRESHOLD="HIGH"     # Gate threshold: CRITICAL, HIGH, MEDIUM, LOW
OUTPUT_DIR="${PROJECT_ROOT}/security/reports/${TIMESTAMP}"
SKIP_TRIVY=false
SKIP_BANDIT=false
SKIP_NPM_AUDIT=false
SKIP_OWASP_DC=false
VERBOSE=false
DRY_RUN=false

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
${BOLD}NeuroSphere Security Scanner${NC}

${CYAN}Usage:${NC}
    $(basename "$0") [OPTIONS]

${CYAN}Options:${NC}
    -s, --service NAME          Scan a specific service (default: all)
    -t, --severity-threshold    Gate threshold: CRITICAL|HIGH|MEDIUM|LOW (default: HIGH)
    -o, --output-dir DIR        Output directory for reports (default: security/reports/<timestamp>)
        --skip-trivy            Skip Trivy container scanning
        --skip-bandit           Skip Bandit Python SAST
        --skip-npm-audit        Skip npm audit
        --skip-owasp-dc         Skip OWASP Dependency-Check
    -v, --verbose               Verbose output
    -n, --dry-run               Show what would be scanned without running
    -h, --help                  Show this help message

${CYAN}Examples:${NC}
    # Scan all services with default settings
    $(basename "$0")

    # Scan only the telemetry-ingest service
    $(basename "$0") --service telemetry-ingest

    # Scan with CRITICAL-only gate, custom output dir
    $(basename "$0") -t CRITICAL -o /tmp/security-reports

    # Dry run to see what would be scanned
    $(basename "$0") --dry-run

${CYAN}Exit Codes:${NC}
    0  Clean — no findings at or above threshold
    1  Warnings — MEDIUM findings detected
    2  Critical — HIGH or CRITICAL findings detected

EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Argument Parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--service)
            SERVICE="$2"
            shift 2
            ;;
        -t|--severity-threshold)
            SEVERITY_THRESHOLD="$2"
            shift 2
            ;;
        -o|--output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --skip-trivy)
            SKIP_TRIVY=true
            shift
            ;;
        --skip-bandit)
            SKIP_BANDIT=true
            shift
            ;;
        --skip-npm-audit)
            SKIP_NPM_AUDIT=true
            shift
            ;;
        --skip-owasp-dc)
            SKIP_OWASP_DC=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Error: Unknown option: $1${NC}" >&2
            usage
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Logging Helpers
# ---------------------------------------------------------------------------
log_info()  { echo -e "${CYAN}[INFO]${NC}  $(date -u +%H:%M:%S) $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date -u +%H:%M:%S) $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date -u +%H:%M:%S) $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $(date -u +%H:%M:%S) $*"; }
log_section() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  $*${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
}

# Update the maximum exit code (higher = worse)
update_exit_code() {
    local code=$1
    if [[ $code -gt $MAX_EXIT_CODE ]]; then
        MAX_EXIT_CODE=$code
    fi
}

# Check if a command exists
require_cmd() {
    if ! command -v "$1" &>/dev/null; then
        log_warn "Tool not found: $1 — skipping related scans"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Service Discovery
# ---------------------------------------------------------------------------
discover_services() {
    local services=()
    local services_dir="${PROJECT_ROOT}/services"

    if [[ -n "$SERVICE" ]]; then
        if [[ -d "${services_dir}/${SERVICE}" ]]; then
            services+=("$SERVICE")
        else
            log_error "Service not found: ${SERVICE}"
            exit 1
        fi
    elif [[ -d "$services_dir" ]]; then
        for svc_dir in "${services_dir}"/*/; do
            if [[ -d "$svc_dir" ]]; then
                services+=("$(basename "$svc_dir")")
            fi
        done
    fi

    echo "${services[@]}"
}

detect_service_type() {
    local svc_dir="$1"
    if [[ -f "${svc_dir}/requirements.txt" ]] || [[ -f "${svc_dir}/Pipfile" ]] || [[ -f "${svc_dir}/pyproject.toml" ]]; then
        echo "python"
    elif [[ -f "${svc_dir}/package.json" ]]; then
        echo "nodejs"
    elif [[ -f "${svc_dir}/go.mod" ]]; then
        echo "golang"
    else
        echo "unknown"
    fi
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
log_section "NeuroSphere Security Scanner — ${TIMESTAMP}"
log_info "Project root:        ${PROJECT_ROOT}"
log_info "Severity threshold:  ${SEVERITY_THRESHOLD}"
log_info "Output directory:    ${OUTPUT_DIR}"

mkdir -p "${OUTPUT_DIR}"/{trivy,bandit,npm-audit,owasp-dc}

# Initialize consolidated report
CONSOLIDATED_REPORT="${OUTPUT_DIR}/consolidated-report.json"
cat > "$CONSOLIDATED_REPORT" <<EOF
{
  "scan_id": "neurosphere-scan-${TIMESTAMP}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "project": "NeuroSphere Medical Robotics",
  "severity_threshold": "${SEVERITY_THRESHOLD}",
  "scanners": {},
  "summary": {}
}
EOF

# Discover services
SERVICES=($(discover_services))
log_info "Services to scan:    ${SERVICES[*]:-none discovered}"

if $DRY_RUN; then
    log_info "Dry run mode — showing scan plan only"
    echo ""
    echo "Scan Plan:"
    echo "  Trivy:       $( $SKIP_TRIVY && echo 'SKIP' || echo 'RUN' )"
    echo "  Bandit:      $( $SKIP_BANDIT && echo 'SKIP' || echo 'RUN' )"
    echo "  npm audit:   $( $SKIP_NPM_AUDIT && echo 'SKIP' || echo 'RUN' )"
    echo "  OWASP DC:    $( $SKIP_OWASP_DC && echo 'SKIP' || echo 'RUN' )"
    echo "  Services:    ${SERVICES[*]:-none}"
    exit 0
fi

# Track scan results for summary table
declare -A SCAN_RESULTS

# ---------------------------------------------------------------------------
# Phase 1: Trivy Container & Filesystem Scanning
# ---------------------------------------------------------------------------
if ! $SKIP_TRIVY; then
    log_section "Phase 1: Trivy Container & Filesystem Scanning"

    if require_cmd trivy; then
        TRIVY_CRITICAL=0
        TRIVY_HIGH=0
        TRIVY_MEDIUM=0

        for svc in "${SERVICES[@]}"; do
            svc_dir="${PROJECT_ROOT}/services/${svc}"
            log_info "Scanning filesystem: ${svc}"

            trivy_output="${OUTPUT_DIR}/trivy/${svc}-fs.json"

            # Filesystem scan (source code + dependencies)
            if trivy fs \
                --config "${TRIVY_CONFIG}" \
                --format json \
                --output "${trivy_output}" \
                --severity "CRITICAL,HIGH,MEDIUM" \
                "${svc_dir}" 2>/dev/null; then
                log_ok "Trivy filesystem scan complete: ${svc}"
            else
                log_warn "Trivy filesystem scan had findings: ${svc}"
            fi

            # Count findings by severity from JSON output
            if [[ -f "${trivy_output}" ]]; then
                local_critical=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length' "${trivy_output}" 2>/dev/null || echo 0)
                local_high=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "HIGH")] | length' "${trivy_output}" 2>/dev/null || echo 0)
                local_medium=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "MEDIUM")] | length' "${trivy_output}" 2>/dev/null || echo 0)
                TRIVY_CRITICAL=$((TRIVY_CRITICAL + local_critical))
                TRIVY_HIGH=$((TRIVY_HIGH + local_high))
                TRIVY_MEDIUM=$((TRIVY_MEDIUM + local_medium))
            fi

            # Docker image scan (if Dockerfile exists and image is built)
            if [[ -f "${svc_dir}/Dockerfile" ]]; then
                image_name="neurosphere/${svc}:latest"
                if docker image inspect "${image_name}" &>/dev/null; then
                    log_info "Scanning Docker image: ${image_name}"
                    trivy image \
                        --config "${TRIVY_CONFIG}" \
                        --format json \
                        --output "${OUTPUT_DIR}/trivy/${svc}-image.json" \
                        --severity "CRITICAL,HIGH,MEDIUM" \
                        "${image_name}" 2>/dev/null || true
                    log_ok "Trivy image scan complete: ${image_name}"
                else
                    log_warn "Docker image not found locally: ${image_name} — skipping image scan"
                fi
            fi
        done

        SCAN_RESULTS["trivy"]="${TRIVY_CRITICAL}c/${TRIVY_HIGH}h/${TRIVY_MEDIUM}m"

        if [[ $TRIVY_CRITICAL -gt 0 ]]; then
            update_exit_code 2
        elif [[ $TRIVY_HIGH -gt 0 ]]; then
            [[ "$SEVERITY_THRESHOLD" == "HIGH" || "$SEVERITY_THRESHOLD" == "MEDIUM" || "$SEVERITY_THRESHOLD" == "LOW" ]] && update_exit_code 2
        elif [[ $TRIVY_MEDIUM -gt 0 ]]; then
            [[ "$SEVERITY_THRESHOLD" == "MEDIUM" || "$SEVERITY_THRESHOLD" == "LOW" ]] && update_exit_code 1
        fi

        log_info "Trivy totals: ${TRIVY_CRITICAL} CRITICAL, ${TRIVY_HIGH} HIGH, ${TRIVY_MEDIUM} MEDIUM"
    else
        SCAN_RESULTS["trivy"]="SKIPPED (not installed)"
    fi
else
    log_info "Trivy scanning skipped (--skip-trivy)"
    SCAN_RESULTS["trivy"]="SKIPPED"
fi

# ---------------------------------------------------------------------------
# Phase 2: Bandit Python SAST
# ---------------------------------------------------------------------------
if ! $SKIP_BANDIT; then
    log_section "Phase 2: Bandit Python Static Analysis"

    if require_cmd bandit; then
        BANDIT_HIGH=0
        BANDIT_MEDIUM=0
        BANDIT_LOW=0

        for svc in "${SERVICES[@]}"; do
            svc_dir="${PROJECT_ROOT}/services/${svc}"
            svc_type=$(detect_service_type "${svc_dir}")

            if [[ "$svc_type" != "python" ]]; then
                $VERBOSE && log_info "Skipping non-Python service: ${svc}"
                continue
            fi

            log_info "Running Bandit on: ${svc}"
            bandit_output="${OUTPUT_DIR}/bandit/${svc}.json"

            bandit \
                -c "${BANDIT_CONFIG}" \
                -r "${svc_dir}" \
                -f json \
                -o "${bandit_output}" \
                --exit-zero \
                2>/dev/null || true

            if [[ -f "${bandit_output}" ]]; then
                local_high=$(jq '[.results[] | select(.issue_severity == "HIGH")] | length' "${bandit_output}" 2>/dev/null || echo 0)
                local_medium=$(jq '[.results[] | select(.issue_severity == "MEDIUM")] | length' "${bandit_output}" 2>/dev/null || echo 0)
                local_low=$(jq '[.results[] | select(.issue_severity == "LOW")] | length' "${bandit_output}" 2>/dev/null || echo 0)
                BANDIT_HIGH=$((BANDIT_HIGH + local_high))
                BANDIT_MEDIUM=$((BANDIT_MEDIUM + local_medium))
                BANDIT_LOW=$((BANDIT_LOW + local_low))
                log_ok "Bandit scan complete: ${svc} (${local_high}H/${local_medium}M/${local_low}L)"
            fi
        done

        SCAN_RESULTS["bandit"]="${BANDIT_HIGH}h/${BANDIT_MEDIUM}m/${BANDIT_LOW}l"

        if [[ $BANDIT_HIGH -gt 0 ]]; then
            update_exit_code 2
        elif [[ $BANDIT_MEDIUM -gt 0 ]]; then
            [[ "$SEVERITY_THRESHOLD" == "MEDIUM" || "$SEVERITY_THRESHOLD" == "LOW" ]] && update_exit_code 1
        fi

        log_info "Bandit totals: ${BANDIT_HIGH} HIGH, ${BANDIT_MEDIUM} MEDIUM, ${BANDIT_LOW} LOW"
    else
        SCAN_RESULTS["bandit"]="SKIPPED (not installed)"
    fi
else
    log_info "Bandit scanning skipped (--skip-bandit)"
    SCAN_RESULTS["bandit"]="SKIPPED"
fi

# ---------------------------------------------------------------------------
# Phase 3: npm audit (Node.js services)
# ---------------------------------------------------------------------------
if ! $SKIP_NPM_AUDIT; then
    log_section "Phase 3: npm Audit (Node.js Services)"

    if require_cmd npm; then
        NPM_CRITICAL=0
        NPM_HIGH=0
        NPM_MODERATE=0

        for svc in "${SERVICES[@]}"; do
            svc_dir="${PROJECT_ROOT}/services/${svc}"
            svc_type=$(detect_service_type "${svc_dir}")

            if [[ "$svc_type" != "nodejs" ]]; then
                $VERBOSE && log_info "Skipping non-Node.js service: ${svc}"
                continue
            fi

            log_info "Running npm audit on: ${svc}"
            npm_output="${OUTPUT_DIR}/npm-audit/${svc}.json"

            (cd "${svc_dir}" && npm audit --json > "${npm_output}" 2>/dev/null) || true

            if [[ -f "${npm_output}" ]]; then
                local_critical=$(jq '.metadata.vulnerabilities.critical // 0' "${npm_output}" 2>/dev/null || echo 0)
                local_high=$(jq '.metadata.vulnerabilities.high // 0' "${npm_output}" 2>/dev/null || echo 0)
                local_moderate=$(jq '.metadata.vulnerabilities.moderate // 0' "${npm_output}" 2>/dev/null || echo 0)
                NPM_CRITICAL=$((NPM_CRITICAL + local_critical))
                NPM_HIGH=$((NPM_HIGH + local_high))
                NPM_MODERATE=$((NPM_MODERATE + local_moderate))
                log_ok "npm audit complete: ${svc} (${local_critical}C/${local_high}H/${local_moderate}M)"
            fi
        done

        SCAN_RESULTS["npm_audit"]="${NPM_CRITICAL}c/${NPM_HIGH}h/${NPM_MODERATE}m"

        if [[ $NPM_CRITICAL -gt 0 ]]; then
            update_exit_code 2
        elif [[ $NPM_HIGH -gt 0 ]]; then
            [[ "$SEVERITY_THRESHOLD" == "HIGH" || "$SEVERITY_THRESHOLD" == "MEDIUM" || "$SEVERITY_THRESHOLD" == "LOW" ]] && update_exit_code 2
        elif [[ $NPM_MODERATE -gt 0 ]]; then
            [[ "$SEVERITY_THRESHOLD" == "MEDIUM" || "$SEVERITY_THRESHOLD" == "LOW" ]] && update_exit_code 1
        fi

        log_info "npm audit totals: ${NPM_CRITICAL} CRITICAL, ${NPM_HIGH} HIGH, ${NPM_MODERATE} MODERATE"
    else
        SCAN_RESULTS["npm_audit"]="SKIPPED (not installed)"
    fi
else
    log_info "npm audit skipped (--skip-npm-audit)"
    SCAN_RESULTS["npm_audit"]="SKIPPED"
fi

# ---------------------------------------------------------------------------
# Phase 4: OWASP Dependency-Check
# ---------------------------------------------------------------------------
if ! $SKIP_OWASP_DC; then
    log_section "Phase 4: OWASP Dependency-Check (SCA)"

    if require_cmd dependency-check; then
        OWASP_OUTPUT="${OUTPUT_DIR}/owasp-dc"

        log_info "Running OWASP Dependency-Check on project root"

        dependency-check \
            --project "NeuroSphere" \
            --scan "${PROJECT_ROOT}/services" \
            --format JSON \
            --format HTML \
            --out "${OWASP_OUTPUT}" \
            --suppression "${OWASP_SUPPRESSION}" \
            --failOnCVSS 7 \
            --enableExperimental \
            2>/dev/null || update_exit_code 2

        if [[ -f "${OWASP_OUTPUT}/dependency-check-report.json" ]]; then
            owasp_vulns=$(jq '[.dependencies[]?.vulnerabilities[]?] | length' \
                "${OWASP_OUTPUT}/dependency-check-report.json" 2>/dev/null || echo 0)
            SCAN_RESULTS["owasp_dc"]="${owasp_vulns} vulnerabilities"
            log_ok "OWASP Dependency-Check complete: ${owasp_vulns} findings"
        else
            SCAN_RESULTS["owasp_dc"]="completed (no JSON output)"
        fi
    else
        SCAN_RESULTS["owasp_dc"]="SKIPPED (not installed)"
        log_warn "Install dependency-check: https://jeremylong.github.io/DependencyCheck/"
    fi
else
    log_info "OWASP Dependency-Check skipped (--skip-owasp-dc)"
    SCAN_RESULTS["owasp_dc"]="SKIPPED"
fi

# ---------------------------------------------------------------------------
# Phase 5: Generate Consolidated HTML Report
# ---------------------------------------------------------------------------
log_section "Phase 5: Generating Consolidated Report"

HTML_REPORT="${OUTPUT_DIR}/security-scan-report.html"

cat > "${HTML_REPORT}" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>NeuroSphere Security Scan Report</title>
    <style>
        :root { --bg: #0a0e17; --card: #131a2b; --border: #1e2d4a; --text: #c9d1d9;
                --critical: #f85149; --high: #f0883e; --medium: #d29922; --low: #3fb950;
                --accent: #58a6ff; }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, 'Segoe UI', sans-serif; background: var(--bg); color: var(--text); padding: 2rem; }
        .header { text-align: center; margin-bottom: 2rem; }
        .header h1 { color: var(--accent); font-size: 1.8rem; margin-bottom: 0.5rem; }
        .header .subtitle { color: #8b949e; }
        .summary-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 1rem; margin-bottom: 2rem; }
        .summary-card { background: var(--card); border: 1px solid var(--border); border-radius: 8px; padding: 1.5rem; text-align: center; }
        .summary-card .count { font-size: 2rem; font-weight: bold; }
        .summary-card .label { color: #8b949e; font-size: 0.875rem; text-transform: uppercase; }
        .critical { color: var(--critical); border-color: var(--critical); }
        .high { color: var(--high); border-color: var(--high); }
        .medium { color: var(--medium); border-color: var(--medium); }
        .clean { color: var(--low); border-color: var(--low); }
        table { width: 100%; border-collapse: collapse; background: var(--card); border-radius: 8px; overflow: hidden; }
        th, td { padding: 0.75rem 1rem; text-align: left; border-bottom: 1px solid var(--border); }
        th { background: #1c2333; color: var(--accent); font-size: 0.875rem; text-transform: uppercase; }
        .badge { padding: 2px 8px; border-radius: 12px; font-size: 0.75rem; font-weight: 600; }
        .badge-critical { background: rgba(248,81,73,0.15); color: var(--critical); }
        .badge-high { background: rgba(240,136,62,0.15); color: var(--high); }
        .badge-medium { background: rgba(210,153,34,0.15); color: var(--medium); }
        .badge-clean { background: rgba(63,185,80,0.15); color: var(--low); }
        .footer { text-align: center; margin-top: 2rem; color: #484f58; font-size: 0.8rem; }
    </style>
</head>
<body>
    <div class="header">
        <h1>🛡️ NeuroSphere Security Scan Report</h1>
        <p class="subtitle">Medical Robotics Platform — Automated Security Assessment</p>
    </div>
    <p style="text-align:center; margin-bottom:2rem; color:#8b949e;">
        Report auto-generated by <code>run-security-scan.sh</code>.
        See individual JSON reports in the output directory for detailed findings.
    </p>
    <div class="footer">
        <p>NeuroSphere Medical Robotics — Confidential Security Report</p>
        <p>Compliance: HIPAA §164.312 | IEC 62443 | FDA 21 CFR Part 11</p>
    </div>
</body>
</html>
HTMLEOF

log_ok "HTML report generated: ${HTML_REPORT}"

# ---------------------------------------------------------------------------
# Phase 6: Summary Table
# ---------------------------------------------------------------------------
log_section "Scan Summary"

printf "\n"
printf "  ${BOLD}%-20s %-35s %-12s${NC}\n" "Scanner" "Findings" "Status"
printf "  %-20s %-35s %-12s\n" "────────────────────" "───────────────────────────────────" "────────────"

for scanner in trivy bandit npm_audit owasp_dc; do
    result="${SCAN_RESULTS[$scanner]:-N/A}"
    if [[ "$result" == *"SKIPPED"* ]]; then
        status="${YELLOW}SKIPPED${NC}"
    elif [[ "$result" == "0"* ]] || [[ "$result" == "completed"* ]]; then
        status="${GREEN}PASS${NC}"
    else
        status="${RED}FINDINGS${NC}"
    fi
    printf "  %-20s %-35s ${status}\n" "$scanner" "$result"
done

printf "\n"
log_info "Reports saved to: ${OUTPUT_DIR}"
log_info "Consolidated JSON: ${CONSOLIDATED_REPORT}"
log_info "HTML Report:       ${HTML_REPORT}"

# ---------------------------------------------------------------------------
# Final Exit
# ---------------------------------------------------------------------------
if [[ $MAX_EXIT_CODE -eq 0 ]]; then
    log_ok "All scans passed — no findings at or above ${SEVERITY_THRESHOLD} threshold"
elif [[ $MAX_EXIT_CODE -eq 1 ]]; then
    log_warn "Scan completed with warnings (MEDIUM findings detected)"
else
    log_error "Scan completed with CRITICAL/HIGH findings — review required before deployment"
fi

exit $MAX_EXIT_CODE
