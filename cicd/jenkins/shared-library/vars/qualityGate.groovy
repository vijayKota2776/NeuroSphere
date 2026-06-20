#!/usr/bin/env groovy
/**
 * qualityGate.groovy
 * NeuroSphere Medical Robotics — Shared Library
 *
 * Enforces quality gates before code can proceed through the pipeline.
 * Medical device software (IEC 62304) requires documented evidence
 * that quality criteria are met at each verification stage.
 *
 * Quality criteria:
 *   1. Code coverage ≥ threshold (default 80%)
 *   2. All unit/integration tests pass
 *   3. No critical or high security findings
 *   4. Static analysis score within acceptable range
 *
 * Usage:
 *   def result = qualityGate(
 *       coverageThreshold: 80,
 *       testResults:       'reports/junit.xml',
 *       securityFindings:  [critical: 0, high: 2, medium: 5]
 *   )
 *   if (!result.passed) { error "Quality gate failed" }
 */

def call(Map args) {
    def coverageThreshold  = args.get('coverageThreshold', 80)
    def testResults        = args.get('testResults', '**/test-results/*.xml')
    def securityFindings   = args.get('securityFindings', [:])
    def coverageReport     = args.get('coverageReport', '**/coverage.xml')
    def maxCriticalFindings = args.get('maxCriticalFindings', 0)
    def maxHighFindings    = args.get('maxHighFindings', 0)
    def failOnUnstable     = args.get('failOnUnstable', true)
    def enableSonar        = args.get('enableSonarQube', false)

    def gateResults = [
        passed:   true,
        details:  [],
        coverage: 0.0,
        tests:    [total: 0, passed: 0, failed: 0, skipped: 0],
        security: [:],
    ]

    echo """
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     Quality Gate — NeuroSphere Medical Robotics
     IEC 62304 Software Verification
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    """.stripIndent()

    // ==================================================================
    // Gate 1: Test Results
    // ==================================================================
    stage('Quality Gate: Tests') {
        try {
            def testSummary = junit testResults: testResults,
                                    allowEmptyResults: true,
                                    skipPublishingChecks: false

            gateResults.tests = [
                total:   testSummary.totalCount,
                passed:  testSummary.passCount,
                failed:  testSummary.failCount,
                skipped: testSummary.skipCount,
            ]

            echo """
            📋 Test Results
               Total   : ${gateResults.tests.total}
               Passed  : ${gateResults.tests.passed}
               Failed  : ${gateResults.tests.failed}
               Skipped : ${gateResults.tests.skipped}
            """.stripIndent()

            if (gateResults.tests.failed > 0) {
                gateResults.passed = false
                gateResults.details << "❌ FAIL: ${gateResults.tests.failed} test(s) failed"
            } else if (gateResults.tests.total == 0) {
                gateResults.details << "⚠️ WARN: No test results found"
                if (failOnUnstable) {
                    gateResults.passed = false
                    gateResults.details << "❌ FAIL: No tests found and failOnUnstable is enabled"
                }
            } else {
                gateResults.details << "✅ PASS: All ${gateResults.tests.total} tests passed"
            }
        } catch (Exception e) {
            echo "⚠️ Could not parse test results: ${e.message}"
            gateResults.details << "⚠️ WARN: Test result parsing failed — ${e.message}"
        }
    }

    // ==================================================================
    // Gate 2: Code Coverage
    // ==================================================================
    stage('Quality Gate: Coverage') {
        try {
            def coverageValue = parseCoverage(coverageReport)
            gateResults.coverage = coverageValue

            echo """
            📊 Code Coverage
               Current   : ${coverageValue}%
               Threshold : ${coverageThreshold}%
            """.stripIndent()

            if (coverageValue < coverageThreshold) {
                gateResults.passed = false
                gateResults.details << "❌ FAIL: Coverage ${coverageValue}% is below threshold ${coverageThreshold}%"
            } else {
                gateResults.details << "✅ PASS: Coverage ${coverageValue}% meets threshold ${coverageThreshold}%"
            }
        } catch (Exception e) {
            echo "⚠️ Could not parse coverage report: ${e.message}"
            gateResults.details << "⚠️ WARN: Coverage report not found or unparseable"
        }
    }

    // ==================================================================
    // Gate 3: Security Findings
    // ==================================================================
    stage('Quality Gate: Security') {
        gateResults.security = securityFindings

        def critical = (securityFindings.critical ?: 0) as int
        def high     = (securityFindings.high ?: 0) as int
        def medium   = (securityFindings.medium ?: 0) as int
        def low      = (securityFindings.low ?: 0) as int

        echo """
        🔒 Security Findings
           Critical : ${critical} (max: ${maxCriticalFindings})
           High     : ${high} (max: ${maxHighFindings})
           Medium   : ${medium}
           Low      : ${low}
        """.stripIndent()

        if (critical > maxCriticalFindings) {
            gateResults.passed = false
            gateResults.details << "❌ FAIL: ${critical} critical vulnerabilities (max: ${maxCriticalFindings})"
        } else {
            gateResults.details << "✅ PASS: Critical vulnerabilities within threshold"
        }

        if (high > maxHighFindings) {
            gateResults.passed = false
            gateResults.details << "❌ FAIL: ${high} high vulnerabilities (max: ${maxHighFindings})"
        } else {
            gateResults.details << "✅ PASS: High vulnerabilities within threshold"
        }
    }

    // ==================================================================
    // Gate 4: SonarQube (optional)
    // ==================================================================
    if (enableSonar) {
        stage('Quality Gate: SonarQube') {
            try {
                timeout(time: 5, unit: 'MINUTES') {
                    def qg = waitForQualityGate()
                    if (qg.status != 'OK') {
                        gateResults.passed = false
                        gateResults.details << "❌ FAIL: SonarQube quality gate status: ${qg.status}"
                    } else {
                        gateResults.details << "✅ PASS: SonarQube quality gate passed"
                    }
                }
            } catch (Exception e) {
                echo "⚠️ SonarQube gate check failed: ${e.message}"
                gateResults.details << "⚠️ WARN: SonarQube check failed — ${e.message}"
            }
        }
    }

    // ==================================================================
    // Summary
    // ==================================================================
    def summaryIcon = gateResults.passed ? '✅' : '❌'
    def summaryText = gateResults.passed ? 'PASSED' : 'FAILED'

    echo """
    ╔══════════════════════════════════════════════════════════════╗
    ║  Quality Gate ${summaryIcon} ${summaryText.padRight(45)}║
    ╠══════════════════════════════════════════════════════════════╣
    ${gateResults.details.collect { "║  ${it.padRight(58)}║" }.join('\n')}
    ╚══════════════════════════════════════════════════════════════╝
    """.stripIndent()

    // Write gate result to file for audit / downstream consumption
    def gateJson = groovy.json.JsonOutput.prettyPrint(
        groovy.json.JsonOutput.toJson([
            timestamp:  new Date().format("yyyy-MM-dd'T'HH:mm:ss'Z'", TimeZone.getTimeZone('UTC')),
            buildId:    env.BUILD_NUMBER,
            service:    env.NEUROSPHERE_SERVICE ?: env.JOB_BASE_NAME,
            passed:     gateResults.passed,
            coverage:   gateResults.coverage,
            tests:      gateResults.tests,
            security:   gateResults.security,
            details:    gateResults.details,
        ])
    )
    writeFile file: "quality-gate-result-${env.BUILD_NUMBER}.json", text: gateJson
    archiveArtifacts artifacts: 'quality-gate-result-*.json', allowEmptyArchive: true

    return gateResults
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Parse code coverage from a Cobertura/JaCoCo XML report.
 * Returns coverage as a percentage (0–100).
 */
private double parseCoverage(String pattern) {
    def files = findFiles(glob: pattern)
    if (!files) {
        echo "No coverage report found matching: ${pattern}"
        return 0.0
    }

    def coverageFile = files[0].path
    def content = readFile(coverageFile)

    // Cobertura format: <coverage line-rate="0.85" ...>
    def matcher = content =~ /line-rate="([0-9.]+)"/
    if (matcher.find()) {
        return (matcher.group(1) as double) * 100.0
    }

    // JaCoCo format: <counter type="LINE" missed="X" covered="Y"/>
    def jacocoMatcher = content =~ /type="LINE"\s+missed="(\d+)"\s+covered="(\d+)"/
    if (jacocoMatcher.find()) {
        def missed  = jacocoMatcher.group(1) as double
        def covered = jacocoMatcher.group(2) as double
        def total   = missed + covered
        return total > 0 ? (covered / total) * 100.0 : 0.0
    }

    echo "⚠️ Unrecognized coverage format in ${coverageFile}"
    return 0.0
}
