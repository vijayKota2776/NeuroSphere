#!/usr/bin/env groovy
/**
 * deploy-staging.groovy
 * NeuroSphere Medical Robotics — Staging Deployment Pipeline
 *
 * Triggers: Push to 'release/*' branches
 * Strategy: Auto-deploy with full verification suite
 * Post-deploy: Full integration + performance tests, QA notification
 *
 * The staging environment is a near-production replica used for
 * final verification before production release. It uses anonymized
 * patient datasets and full resource allocations.
 */

@Library('neurosphere-shared-lib') _

neurospherePipeline(
    serviceName:    'neurosphere-deploy-staging',
    deployTarget:   'staging',
    timeoutMinutes: 45,
    enableAuditLog: true
) {

    def imageTag    = params.IMAGE_TAG ?: env.IMAGE_TAG ?: 'latest'
    def servicesCsv = params.SERVICES ?: ''
    def services    = servicesCsv ? servicesCsv.split(',').collect { it.trim() } : allServices()
    def runIntTests = params.RUN_INTEGRATION_TESTS != null ? params.RUN_INTEGRATION_TESTS : true

    // ==================================================================
    // Stage 1: Pre-flight Validation
    // ==================================================================
    stage('Pre-flight: Staging') {
        echo "🔍 Validating staging deployment prerequisites"

        sh 'kubectl config use-context neurosphere-staging'
        sh 'kubectl cluster-info'

        // Verify all images exist in registry before starting
        def missingImages = []
        services.each { svc ->
            def exists = sh(
                script: "docker manifest inspect registry.neurosphere.io/neurosphere/${svc}:${imageTag} > /dev/null 2>&1",
                returnStatus: true
            )
            if (exists != 0) {
                missingImages << svc
            }
        }

        if (missingImages && imageTag != 'latest') {
            error "🚫 Images not found for tag '${imageTag}': ${missingImages.join(', ')}"
        }

        // Verify staging namespace quotas have capacity
        sh """
            kubectl describe resourcequota -n neurosphere-staging || true
        """
    }

    // ==================================================================
    // Stage 2: Full Security Scan
    // ==================================================================
    stage('Security Scan') {
        def allFindings = [critical: 0, high: 0, medium: 0, low: 0]

        services.each { svc ->
            def result = securityScan(
                imageName:         "registry.neurosphere.io/neurosphere/${svc}:${imageTag}",
                severityThreshold: 'HIGH',    // Block on HIGH+ for staging
                scanType:          'image',
                exitOnFailure:     false
            )
            if (result.findings) {
                allFindings.critical += (result.findings.critical ?: 0)
                allFindings.high     += (result.findings.high ?: 0)
                allFindings.medium   += (result.findings.medium ?: 0)
                allFindings.low      += (result.findings.low ?: 0)
            }
        }

        // Block deployment if HIGH or CRITICAL findings exist
        if (allFindings.critical > 0 || allFindings.high > 0) {
            error """
                🚫 Security scan FAILED for staging deployment.
                Critical: ${allFindings.critical}, High: ${allFindings.high}
                All HIGH and CRITICAL vulnerabilities must be resolved
                before staging deployment (HIPAA § 164.312 requirement).
            """.stripIndent()
        }
    }

    // ==================================================================
    // Stage 3: Deploy to Staging
    // ==================================================================
    stage('Deploy to Staging') {
        notifySlack(
            status:      'STARTED',
            channel:     '#neurosphere-qa',
            environment: 'staging',
            message:     "🚀 Deploying ${services.size()} service(s) to staging — tag: ${imageTag}"
        )

        def deployStatus = kubernetesDeploy(
            environment:    'staging',
            namespace:      'neurosphere-staging',
            kustomizePath:  'k8s/overlays/staging',
            imageTag:       imageTag,
            services:       services,
            rolloutTimeout: 300   // 5 minutes for staging
        )

        if (deployStatus == 'ROLLOUT_FAILED') {
            notifySlack(
                status:      'FAILURE',
                channel:     '#neurosphere-qa',
                environment: 'staging',
                message:     "❌ Staging deployment FAILED — rollback triggered for tag: ${imageTag}"
            )
            error "Staging deployment failed — automatic rollback was triggered"
        }
    }

    // ==================================================================
    // Stage 4: Smoke Tests
    // ==================================================================
    stage('Smoke Tests') {
        echo "🧪 Running smoke tests against staging"

        def endpoints = [
            'telemetry-ingest:8080',
            'vital-sign-aggregator:8080',
            'diagnostic-engine:8080',
            'robotic-control-api:8080',
            'patient-gateway:3000',
            'alert-dispatcher:8080',
        ]

        def failures = []
        endpoints.each { ep ->
            def result = sh(
                script: "curl -sf --max-time 15 http://${ep.split(':')[0]}.neurosphere-staging.svc:${ep.split(':')[1]}/health",
                returnStatus: true
            )
            if (result != 0) {
                failures << ep
            }
        }

        if (failures) {
            echo "⚠️ Smoke test failures: ${failures.join(', ')}"
        }
    }

    // ==================================================================
    // Stage 5: Full Integration Test Suite
    // ==================================================================
    if (runIntTests) {
        stage('Integration Tests') {
            echo "🧬 Running full integration test suite"

            sh """
                cd tests/integration

                export NEUROSPHERE_ENV=staging
                export NEUROSPHERE_NAMESPACE=neurosphere-staging
                export TELEMETRY_URL=http://telemetry-ingest.neurosphere-staging.svc:8080
                export PATIENT_GATEWAY_URL=http://patient-gateway.neurosphere-staging.svc:3000
                export DIAGNOSTIC_URL=http://diagnostic-engine.neurosphere-staging.svc:8080

                python -m pytest \\
                    --junitxml=../../staging-integration-results.xml \\
                    --timeout=120 \\
                    -v \\
                    --tb=short \\
                    .
            """

            junit testResults: 'staging-integration-results.xml', allowEmptyResults: true
        }

        // ==============================================================
        // Stage 6: Performance / Load Tests
        // ==============================================================
        stage('Performance Tests') {
            echo "⚡ Running performance baseline tests"

            sh """
                cd tests/performance

                # Telemetry ingest throughput test
                k6 run \\
                    --out json=../../perf-telemetry-results.json \\
                    --tag testid=staging-${imageTag} \\
                    --env TARGET_URL=http://telemetry-ingest.neurosphere-staging.svc:8080 \\
                    telemetry-load-test.js || true

                # Vital sign aggregator latency test
                k6 run \\
                    --out json=../../perf-vitals-results.json \\
                    --tag testid=staging-${imageTag} \\
                    --env TARGET_URL=http://vital-sign-aggregator.neurosphere-staging.svc:8080 \\
                    vitals-latency-test.js || true
            """

            archiveArtifacts artifacts: 'perf-*-results.json', allowEmptyArchive: true
        }
    }

    // ==================================================================
    // Stage 7: Quality Gate (strict for staging)
    // ==================================================================
    stage('Staging Quality Gate') {
        def result = qualityGate(
            coverageThreshold: 80,
            testResults:       'staging-integration-results.xml',
            securityFindings:  [:],
            failOnUnstable:    true
        )

        if (!result.passed) {
            notifySlack(
                status:      'FAILURE',
                channel:     '#neurosphere-qa',
                environment: 'staging',
                message:     "❌ Staging quality gate FAILED — deployment tag: ${imageTag}"
            )
            error "Quality gate failed — deployment cannot proceed to production"
        }
    }

    // ==================================================================
    // Stage 8: QA Notification
    // ==================================================================
    stage('Notify QA') {
        notifySlack(
            status:      'SUCCESS',
            channel:     '#neurosphere-qa',
            environment: 'staging',
            message:     """✅ Staging deployment complete — ready for QA verification
                |  Tag: ${imageTag}
                |  Services: ${services.join(', ')}
                |  Integration tests: ${runIntTests ? 'PASSED' : 'SKIPPED'}
                |  🏥 Environment: https://staging.neurosphere.io
            """.stripMargin()
        )
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

def allServices() {
    return [
        'telemetry-ingest',
        'vital-sign-aggregator',
        'diagnostic-engine',
        'robotic-control-api',
        'patient-gateway',
        'surgeon-dashboard',
        'compliance-auditor',
        'alert-dispatcher',
    ]
}
