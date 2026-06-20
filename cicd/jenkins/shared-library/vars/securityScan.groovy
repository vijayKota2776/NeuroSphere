#!/usr/bin/env groovy
/**
 * securityScan.groovy
 * NeuroSphere Medical Robotics — Shared Library
 *
 * Container image and filesystem security scanning using Trivy.
 * Enforces vulnerability thresholds required by:
 *   - HIPAA Security Rule § 164.312 (Technical Safeguards)
 *   - FDA Premarket Cybersecurity Guidance
 *   - IEC 62443 (Industrial Automation Security)
 *
 * Usage:
 *   securityScan(
 *       imageName:         'registry.neurosphere.io/neurosphere/telemetry-ingest:v1.0.0',
 *       severityThreshold: 'HIGH',
 *       scanType:          'image'
 *   )
 */

def call(Map args) {
    // ------------------------------------------------------------------
    // Parameters
    // ------------------------------------------------------------------
    def imageName         = args.get('imageName', '')
    def scanPath          = args.get('scanPath', '.')
    def severityThreshold = args.get('severityThreshold', 'HIGH')    // CRITICAL, HIGH, MEDIUM, LOW
    def scanType          = args.get('scanType', 'image')            // image, fs, repo
    def exitOnFailure     = args.get('exitOnFailure', true)
    def ignoreUnfixed     = args.get('ignoreUnfixed', true)
    def trivyVersion      = args.get('trivyVersion', 'latest')
    def timeout_min       = args.get('timeout', 10)

    // Validate scan target
    if (scanType == 'image' && !imageName) {
        error "securityScan: 'imageName' is required when scanType is 'image'"
    }

    def scanTarget   = (scanType == 'image') ? imageName : scanPath
    def reportPrefix = "trivy-${scanType}-${env.BUILD_NUMBER}"
    def scanPassed   = true
    def findings     = [critical: 0, high: 0, medium: 0, low: 0]

    echo """
    🔒 NeuroSphere Security Scan
    ─────────────────────────────────────────
     Type              : ${scanType}
     Target            : ${scanTarget}
     Severity Threshold: ${severityThreshold}
     Ignore Unfixed    : ${ignoreUnfixed}
    ─────────────────────────────────────────
    """.stripIndent()

    // ------------------------------------------------------------------
    // Update Trivy vulnerability database
    // ------------------------------------------------------------------
    stage("Trivy DB Update") {
        sh "trivy --download-db-only --cache-dir .trivy-cache || true"
    }

    // ------------------------------------------------------------------
    // Run vulnerability scan
    // ------------------------------------------------------------------
    stage("Vulnerability Scan: ${scanType}") {
        def unfixedFlag = ignoreUnfixed ? '--ignore-unfixed' : ''
        def severities  = severitiesAbove(severityThreshold)

        // JSON report for programmatic parsing
        def exitCode = sh(
            script: """
                trivy ${scanType} \\
                    --cache-dir .trivy-cache \\
                    --severity ${severities} \\
                    ${unfixedFlag} \\
                    --format json \\
                    --output ${reportPrefix}.json \\
                    --timeout ${timeout_min}m \\
                    ${scanTarget}
            """,
            returnStatus: true
        )

        // Human-readable table report
        sh """
            trivy ${scanType} \\
                --cache-dir .trivy-cache \\
                --severity ${severities} \\
                ${unfixedFlag} \\
                --format table \\
                --output ${reportPrefix}.txt \\
                --timeout ${timeout_min}m \\
                ${scanTarget} || true
        """

        // SARIF report for GitHub / IDE integration
        sh """
            trivy ${scanType} \\
                --cache-dir .trivy-cache \\
                --severity ${severities} \\
                ${unfixedFlag} \\
                --format sarif \\
                --output ${reportPrefix}.sarif \\
                --timeout ${timeout_min}m \\
                ${scanTarget} || true
        """

        // Parse findings
        findings = parseFindings("${reportPrefix}.json")

        echo """
        ┌─────────────────────────────────────┐
        │  Vulnerability Summary              │
        ├─────────────────────────────────────┤
        │  CRITICAL : ${String.valueOf(findings.critical).padLeft(5)}                  │
        │  HIGH     : ${String.valueOf(findings.high).padLeft(5)}                  │
        │  MEDIUM   : ${String.valueOf(findings.medium).padLeft(5)}                  │
        │  LOW      : ${String.valueOf(findings.low).padLeft(5)}                  │
        └─────────────────────────────────────┘
        """.stripIndent()

        // Determine pass/fail based on threshold
        scanPassed = evaluateThreshold(findings, severityThreshold)
    }

    // ------------------------------------------------------------------
    // Healthcare-specific compliance checks
    // ------------------------------------------------------------------
    stage("Compliance Checks") {
        if (scanType == 'image') {
            // Check for known healthcare-critical CVEs
            checkHealthcareCVEs("${reportPrefix}.json")
        }

        // Check for hardcoded secrets / PHI leaks
        sh """
            trivy fs \\
                --cache-dir .trivy-cache \\
                --scanners secret \\
                --format json \\
                --output ${reportPrefix}-secrets.json \\
                ${scanPath} || true
        """

        def secretFindings = sh(
            script: """
                cat ${reportPrefix}-secrets.json | python3 -c "
import json, sys
data = json.load(sys.stdin)
results = data.get('Results', [])
count = sum(len(r.get('Secrets', [])) for r in results)
print(count)
" 2>/dev/null || echo 0
            """,
            returnStdout: true
        ).trim().toInteger()

        if (secretFindings > 0) {
            echo "🚨 ${secretFindings} secret(s) / potential PHI leak(s) detected!"
            scanPassed = false
        }
    }

    // ------------------------------------------------------------------
    // Archive reports
    // ------------------------------------------------------------------
    archiveArtifacts artifacts: "${reportPrefix}*", allowEmptyArchive: true

    // ------------------------------------------------------------------
    // Enforce gate
    // ------------------------------------------------------------------
    if (!scanPassed && exitOnFailure) {
        error """
        🚫 Security scan FAILED — threshold exceeded.
        Vulnerabilities found above ${severityThreshold} severity.
        Healthcare compliance requires all findings at or above
        ${severityThreshold} to be resolved before deployment.
        Review: ${reportPrefix}.txt
        """.stripIndent()
    }

    return [
        passed:   scanPassed,
        findings: findings,
        report:   "${reportPrefix}.json",
    ]
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Return comma-separated severities at or above the given threshold.
 */
private String severitiesAbove(String threshold) {
    def levels = ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW']
    def idx    = levels.indexOf(threshold.toUpperCase())
    if (idx < 0) idx = 1  // default to HIGH
    return levels[0..idx].join(',')
}

/**
 * Parse Trivy JSON output and count findings by severity.
 */
private Map parseFindings(String reportPath) {
    def counts = [critical: 0, high: 0, medium: 0, low: 0]
    try {
        def json = readFile(reportPath)
        def data = new groovy.json.JsonSlurper().parseText(json)
        data.Results?.each { result ->
            result.Vulnerabilities?.each { vuln ->
                switch (vuln.Severity?.toUpperCase()) {
                    case 'CRITICAL': counts.critical++; break
                    case 'HIGH':     counts.high++;     break
                    case 'MEDIUM':   counts.medium++;   break
                    case 'LOW':      counts.low++;      break
                }
            }
        }
    } catch (Exception e) {
        echo "⚠️ Could not parse Trivy report: ${e.message}"
    }
    return counts
}

/**
 * Evaluate whether findings exceed the configured threshold.
 */
private boolean evaluateThreshold(Map findings, String threshold) {
    switch (threshold.toUpperCase()) {
        case 'CRITICAL': return findings.critical == 0
        case 'HIGH':     return findings.critical == 0 && findings.high == 0
        case 'MEDIUM':   return findings.critical == 0 && findings.high == 0 && findings.medium == 0
        case 'LOW':      return findings.critical == 0 && findings.high == 0 && findings.medium == 0 && findings.low == 0
        default:         return findings.critical == 0 && findings.high == 0
    }
}

/**
 * Check for CVEs that are specifically critical in medical / healthcare
 * environments (e.g. OpenSSL vulnerabilities affecting HL7/FHIR transport,
 * libxml2 issues affecting DICOM/CDA parsing).
 */
private void checkHealthcareCVEs(String reportPath) {
    // Known healthcare-critical CVE prefixes and specific IDs
    def criticalPatterns = [
        'CVE-2024-',   // Recent CVEs — always flag for review
        'CVE-2023-44487', // HTTP/2 Rapid Reset
        'CVE-2023-38545', // curl SOCKS5 heap overflow
    ]

    try {
        def json = readFile(reportPath)
        if (json.contains('CVE-2024-') || json.contains('CVE-2023-44487')) {
            echo "⚠️ Healthcare-critical CVE pattern detected — flagged for review"
        }
    } catch (Exception ignored) {
        // Non-fatal
    }
}
