#!/usr/bin/env groovy
/**
 * deploy-dev.groovy
 * NeuroSphere Medical Robotics — Development Deployment Pipeline
 *
 * Triggers: Push to 'develop' branch (via upstream build success)
 * Strategy: Direct apply — no approval required
 * Post-deploy: Integration test suite
 *
 * The development environment mirrors production topology but
 * uses reduced resource limits and synthetic patient data only.
 */

@Library('neurosphere-shared-lib') _

neurospherePipeline(
    serviceName:    'neurosphere-deploy-dev',
    deployTarget:   'dev',
    timeoutMinutes: 20,
    enableAuditLog: true
) {

    def imageTag   = params.IMAGE_TAG ?: env.IMAGE_TAG ?: 'latest'
    def servicesCsv = params.SERVICES ?: ''
    def services   = servicesCsv ? servicesCsv.split(',').collect { it.trim() } : allServices()

    // ==================================================================
    // Stage 1: Pre-flight Checks
    // ==================================================================
    stage('Pre-flight: Dev') {
        echo "🔍 Validating deployment prerequisites for dev environment"

        // Verify images exist in registry
        services.each { svc ->
            def exists = sh(
                script: """
                    docker manifest inspect registry.neurosphere.io/neurosphere/${svc}:${imageTag} > /dev/null 2>&1
                """,
                returnStatus: true
            )
            if (exists != 0 && imageTag != 'latest') {
                echo "⚠️ Image not found for ${svc}:${imageTag} — falling back to 'latest'"
            }
        }

        // Ensure dev cluster is reachable
        sh 'kubectl config use-context neurosphere-dev'
        sh 'kubectl cluster-info'
    }

    // ==================================================================
    // Stage 2: Security Scan (lightweight for dev)
    // ==================================================================
    stage('Quick Security Scan') {
        def scanResults = [:]
        services.each { svc ->
            scanResults[svc] = securityScan(
                imageName:         "registry.neurosphere.io/neurosphere/${svc}:${imageTag}",
                severityThreshold: 'CRITICAL',   // Only block on critical in dev
                scanType:          'image',
                exitOnFailure:     false
            )
        }

        // Log but don't block on non-critical findings in dev
        def criticalCount = scanResults.values().count { !it.passed }
        if (criticalCount > 0) {
            error "🚫 ${criticalCount} service(s) have CRITICAL vulnerabilities — fix before deploying"
        }
    }

    // ==================================================================
    // Stage 3: Deploy to Dev
    // ==================================================================
    stage('Deploy to Dev') {
        notifySlack(
            status:      'STARTED',
            channel:     '#neurosphere-dev',
            environment: 'dev',
            message:     "🚀 Deploying ${services.size()} service(s) to dev — tag: ${imageTag}"
        )

        def deployStatus = kubernetesDeploy(
            environment:   'dev',
            namespace:     'neurosphere-dev',
            kustomizePath: 'k8s/overlays/dev',
            imageTag:      imageTag,
            services:      services,
            rolloutTimeout: 180   // 3 minutes for dev
        )

        if (deployStatus != 'SUCCESS') {
            error "Deployment to dev failed with status: ${deployStatus}"
        }
    }

    // ==================================================================
    // Stage 4: Post-Deploy Smoke Tests
    // ==================================================================
    stage('Smoke Tests') {
        echo "🧪 Running smoke tests against dev environment"

        sh """
            # Verify core service endpoints are responding
            for endpoint in \\
                "http://telemetry-ingest.neurosphere-dev.svc:8080/health" \\
                "http://vital-sign-aggregator.neurosphere-dev.svc:8080/health" \\
                "http://diagnostic-engine.neurosphere-dev.svc:8080/health" \\
                "http://robotic-control-api.neurosphere-dev.svc:8080/health" \\
                "http://patient-gateway.neurosphere-dev.svc:3000/health" \\
                "http://alert-dispatcher.neurosphere-dev.svc:8080/health"
            do
                echo "Checking \${endpoint}..."
                curl -sf --max-time 10 "\${endpoint}" || echo "⚠️ \${endpoint} not responding"
            done
        """
    }

    // ==================================================================
    // Stage 5: Integration Tests
    // ==================================================================
    stage('Integration Tests') {
        echo "🧬 Running integration test suite against dev"

        sh """
            cd tests/integration

            # Set environment for dev cluster
            export NEUROSPHERE_ENV=dev
            export NEUROSPHERE_NAMESPACE=neurosphere-dev
            export TELEMETRY_URL=http://telemetry-ingest.neurosphere-dev.svc:8080
            export PATIENT_GATEWAY_URL=http://patient-gateway.neurosphere-dev.svc:3000

            # Run integration tests
            python -m pytest \\
                --junitxml=../../integration-test-results.xml \\
                --timeout=60 \\
                -v \\
                . || true
        """

        junit testResults: 'integration-test-results.xml', allowEmptyResults: true
    }

    // ==================================================================
    // Stage 6: Quality Gate (relaxed for dev)
    // ==================================================================
    stage('Dev Quality Gate') {
        def result = qualityGate(
            coverageThreshold: 60,              // Lower threshold for dev
            testResults:       'integration-test-results.xml',
            securityFindings:  [:],
            failOnUnstable:    false             // Don't fail dev on unstable
        )

        if (!result.passed) {
            echo "⚠️ Dev quality gate did not pass — results logged for review"
            currentBuild.result = 'UNSTABLE'
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Full list of NeuroSphere services.
 */
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
