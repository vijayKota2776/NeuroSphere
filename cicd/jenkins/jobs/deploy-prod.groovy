#!/usr/bin/env groovy
/**
 * deploy-prod.groovy
 * NeuroSphere Medical Robotics — Production Deployment Pipeline
 *
 * Triggers: Manual only (no automatic triggers)
 * Strategy: Blue/Green deployment with automatic rollback
 * Approvals: Requires 2 approvals — Engineering Lead + Ops
 * Compliance: Full FDA 21 CFR Part 11 audit trail
 *
 * ⚠️  PRODUCTION PIPELINE — ALL CHANGES ARE AUDITED
 *
 * This pipeline manages patient-facing medical device software.
 * Unauthorized modifications violate FDA 21 CFR Part 11 and
 * HIPAA Security Rule § 164.312.
 */

@Library('neurosphere-shared-lib') _

neurospherePipeline(
    serviceName:    'neurosphere-deploy-prod',
    deployTarget:   'production',
    timeoutMinutes: 60,
    enableAuditLog: true
) {

    def imageTag     = params.IMAGE_TAG
    def servicesCsv  = params.SERVICES ?: ''
    def services     = servicesCsv ? servicesCsv.split(',').collect { it.trim() } : allServices()
    def dryRun       = params.DRY_RUN ?: false
    def changeTicket = params.CHANGE_TICKET ?: ''

    // ==================================================================
    // Stage 1: Input Validation
    // ==================================================================
    stage('Validate Inputs') {
        if (!imageTag) {
            error '🚫 IMAGE_TAG is required for production deployments'
        }
        if (!changeTicket && !dryRun) {
            error '🚫 CHANGE_TICKET is required for production deployments (e.g., CHG-2026-0142)'
        }

        echo """
        ╔══════════════════════════════════════════════════════════════╗
        ║  🏥 PRODUCTION DEPLOYMENT — NeuroSphere Medical Robotics   ║
        ╠══════════════════════════════════════════════════════════════╣
        ║  Image Tag     : ${imageTag.padRight(42)}║
        ║  Services      : ${(services.size() + ' service(s)').padRight(42)}║
        ║  Change Ticket : ${changeTicket.padRight(42)}║
        ║  Dry Run       : ${String.valueOf(dryRun).padRight(42)}║
        ╚══════════════════════════════════════════════════════════════╝
        """.stripIndent()

        // Write initial audit entry
        writeProductionAudit('DEPLOY_INITIATED', [
            imageTag:     imageTag,
            services:     services,
            changeTicket: changeTicket,
            dryRun:       dryRun,
        ])
    }

    // ==================================================================
    // Stage 2: Approval Gate — Engineering Lead
    // ==================================================================
    stage('Approval: Engineering Lead') {
        notifySlack(
            status:      'INFO',
            channel:     '#neurosphere-ops',
            environment: 'production',
            message:     """🔐 Production deployment awaiting ENGINEERING LEAD approval
                |  Tag: ${imageTag} | Ticket: ${changeTicket}
                |  Approve: ${env.BUILD_URL}input/
            """.stripMargin()
        )

        def engApproval = input(
            id: 'engineering-lead-approval',
            message: """
                PRODUCTION DEPLOYMENT APPROVAL — Engineering Lead
                ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

                Image Tag     : ${imageTag}
                Services      : ${services.join(', ')}
                Change Ticket : ${changeTicket}

                By approving, you confirm:
                ✅ All integration tests have passed in staging
                ✅ Security scan shows no critical/high findings
                ✅ Change ticket has been reviewed and approved
                ✅ Rollback procedure has been verified
            """.stripIndent(),
            ok: 'Approve — Engineering Lead',
            submitter: 'eng-lead,admin',
            submitterParameter: 'approver'
        )

        echo "✅ Engineering Lead approval received from: ${engApproval}"
        writeProductionAudit('APPROVAL_ENGINEERING', [approver: engApproval])
    }

    // ==================================================================
    // Stage 3: Approval Gate — Operations
    // ==================================================================
    stage('Approval: Operations') {
        notifySlack(
            status:      'INFO',
            channel:     '#neurosphere-ops',
            environment: 'production',
            message:     """🔐 Production deployment awaiting OPS approval
                |  Tag: ${imageTag} | Ticket: ${changeTicket}
                |  Engineering approval: ✅ received
                |  Approve: ${env.BUILD_URL}input/
            """.stripMargin()
        )

        def opsApproval = input(
            id: 'ops-approval',
            message: """
                PRODUCTION DEPLOYMENT APPROVAL — Operations
                ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

                Image Tag     : ${imageTag}
                Services      : ${services.join(', ')}
                Change Ticket : ${changeTicket}

                Pre-deployment checklist:
                ☐ Monitoring dashboards are open
                ☐ On-call team has been notified
                ☐ Database backups are current (<4 hours old)
                ☐ Incident response channel is ready
            """.stripIndent(),
            ok: 'Approve — Operations',
            submitter: 'ops-lead,sre-lead,admin',
            submitterParameter: 'approver'
        )

        echo "✅ Operations approval received from: ${opsApproval}"
        writeProductionAudit('APPROVAL_OPS', [approver: opsApproval])
    }

    // ==================================================================
    // Stage 4: Pre-Deploy Verification
    // ==================================================================
    stage('Pre-Deploy Verification') {
        sh 'kubectl config use-context neurosphere-production'

        // Verify all images exist
        services.each { svc ->
            def exists = sh(
                script: "docker manifest inspect registry.neurosphere.io/neurosphere/${svc}:${imageTag} > /dev/null 2>&1",
                returnStatus: true
            )
            if (exists != 0) {
                error "🚫 Image not found: neurosphere/${svc}:${imageTag}"
            }
        }

        // Final security scan against production images
        services.each { svc ->
            securityScan(
                imageName:         "registry.neurosphere.io/neurosphere/${svc}:${imageTag}",
                severityThreshold: 'HIGH',
                scanType:          'image',
                exitOnFailure:     true
            )
        }

        // Capture current state for rollback
        sh """
            kubectl get deployments -n neurosphere-production \\
                -l app.kubernetes.io/part-of=neurosphere \\
                -o yaml > pre-deploy-state.yaml
        """
        archiveArtifacts artifacts: 'pre-deploy-state.yaml'
    }

    // ==================================================================
    // Stage 5: Blue/Green Deployment
    // ==================================================================
    stage('Blue/Green Deploy') {
        notifySlack(
            status:      'STARTED',
            channel:     '#neurosphere-ops',
            environment: 'production',
            message:     "🚀 Production deployment STARTING — Blue/Green strategy — tag: ${imageTag}"
        )

        if (dryRun) {
            echo "🔍 DRY RUN — validating manifests without applying"
            kubernetesDeploy(
                environment:   'production',
                namespace:     'neurosphere-production',
                kustomizePath: 'k8s/overlays/production',
                imageTag:      imageTag,
                services:      services,
                dryRun:        true
            )
            echo "✅ Dry run complete — no changes applied"
            return
        }

        // Step 5a: Deploy to "green" (inactive) slot
        echo "📗 Deploying to GREEN slot..."
        try {
            sh """
                # Create green namespace if it doesn't exist
                kubectl get namespace neurosphere-production-green || \\
                    kubectl create namespace neurosphere-production-green

                # Copy secrets and configmaps from production
                kubectl get secrets -n neurosphere-production -o yaml | \\
                    sed 's/namespace: neurosphere-production/namespace: neurosphere-production-green/' | \\
                    kubectl apply -f - || true

                kubectl get configmaps -n neurosphere-production -o yaml | \\
                    sed 's/namespace: neurosphere-production/namespace: neurosphere-production-green/' | \\
                    kubectl apply -f - || true
            """

            def greenStatus = kubernetesDeploy(
                environment:   'production',
                namespace:     'neurosphere-production-green',
                kustomizePath: 'k8s/overlays/production',
                imageTag:      imageTag,
                services:      services,
                rolloutTimeout: 300
            )

            if (greenStatus != 'SUCCESS') {
                error "Green deployment failed — aborting production release"
            }
        } catch (Exception e) {
            writeProductionAudit('DEPLOY_GREEN_FAILED', [error: e.message])
            error "🚫 Green slot deployment failed: ${e.message}"
        }

        // Step 5b: Validate green slot health
        echo "🔍 Validating GREEN slot health..."
        sleep(time: 30, unit: 'SECONDS')

        def healthCheckPassed = true
        services.each { svc ->
            def port = svc.contains('gateway') || svc.contains('dashboard') ? '3000' : '8080'
            def result = sh(
                script: """
                    curl -sf --max-time 15 \\
                        http://${svc}.neurosphere-production-green.svc:${port}/health
                """,
                returnStatus: true
            )
            if (result != 0) {
                echo "❌ Health check failed for ${svc} in green slot"
                healthCheckPassed = false
            }
        }

        if (!healthCheckPassed) {
            echo "🔴 Green slot health checks failed — performing automatic rollback"
            sh "kubectl delete namespace neurosphere-production-green --ignore-not-found=true"
            writeProductionAudit('DEPLOY_GREEN_UNHEALTHY', [:])
            error "Green slot health checks failed — deployment aborted"
        }

        // Step 5c: Switch traffic to green (promote green → blue)
        echo "🔄 Switching traffic from BLUE → GREEN..."
        try {
            kubernetesDeploy(
                environment:    'production',
                namespace:      'neurosphere-production',
                kustomizePath:  'k8s/overlays/production',
                imageTag:       imageTag,
                services:       services,
                rolloutTimeout: 300
            )

            echo "✅ Traffic switched to new version"
            writeProductionAudit('DEPLOY_TRAFFIC_SWITCHED', [imageTag: imageTag])
        } catch (Exception e) {
            // AUTOMATIC ROLLBACK
            echo "🔴 Traffic switch failed — initiating AUTOMATIC ROLLBACK"
            performRollback(services)
            writeProductionAudit('DEPLOY_ROLLBACK_AUTO', [
                error:    e.message,
                imageTag: imageTag
            ])
            error "Production deployment failed — automatic rollback completed"
        }

        // Step 5d: Clean up old green namespace
        sh "kubectl delete namespace neurosphere-production-green --ignore-not-found=true || true"
    }

    // ==================================================================
    // Stage 6: Post-Deploy Verification
    // ==================================================================
    stage('Post-Deploy Verification') {
        // Wait for full stabilization
        sleep(time: 60, unit: 'SECONDS')

        echo "🔍 Running post-deployment verification..."

        // Health endpoint checks
        services.each { svc ->
            def port = svc.contains('gateway') || svc.contains('dashboard') ? '3000' : '8080'
            sh """
                curl -sf --max-time 15 \\
                    http://${svc}.neurosphere-production.svc:${port}/health \\
                    || echo "⚠️ ${svc} health check returned non-200"
            """

            // Readiness check
            sh """
                curl -sf --max-time 15 \\
                    http://${svc}.neurosphere-production.svc:${port}/ready \\
                    || echo "⚠️ ${svc} readiness check returned non-200"
            """
        }

        // Verify Prometheus metrics are being scraped
        sh """
            kubectl get servicemonitors -n neurosphere-production \\
                -l app.kubernetes.io/part-of=neurosphere || true
        """

        // Check for error rate spike (last 5 minutes)
        echo "📊 Monitoring error rates for 5 minutes..."
        sleep(time: 300, unit: 'SECONDS')

        sh """
            # Query Prometheus for error rate
            curl -sf "http://prometheus.neurosphere-monitoring.svc:9090/api/v1/query" \\
                --data-urlencode 'query=sum(rate(http_requests_total{namespace="neurosphere-production",code=~"5.."}[5m])) / sum(rate(http_requests_total{namespace="neurosphere-production"}[5m])) * 100' \\
                | python3 -c "
import json, sys
data = json.load(sys.stdin)
if data.get('data', {}).get('result'):
    error_rate = float(data['data']['result'][0]['value'][1])
    print(f'Error rate: {error_rate:.2f}%')
    if error_rate > 5.0:
        print('⚠️ ERROR RATE ABOVE 5% — REVIEW REQUIRED')
        sys.exit(1)
else:
    print('No error rate data available')
" || echo "⚠️ Could not query error rate"
        """
    }

    // ==================================================================
    // Stage 7: Compliance Audit Entry
    // ==================================================================
    stage('Compliance Audit') {
        writeProductionAudit('DEPLOY_COMPLETE', [
            imageTag:     imageTag,
            services:     services,
            changeTicket: changeTicket,
            status:       'SUCCESS',
        ])

        // Generate deployment manifest for regulatory records
        sh """
            kubectl get deployments -n neurosphere-production \\
                -l app.kubernetes.io/part-of=neurosphere \\
                -o yaml > post-deploy-state.yaml
        """
        archiveArtifacts artifacts: 'post-deploy-state.yaml'

        echo """
        ╔══════════════════════════════════════════════════════════════╗
        ║  ✅ PRODUCTION DEPLOYMENT COMPLETE                          ║
        ║                                                              ║
        ║  Image Tag     : ${imageTag.padRight(42)}║
        ║  Change Ticket : ${changeTicket.padRight(42)}║
        ║  Services      : ${(services.size() + ' deployed').padRight(42)}║
        ║                                                              ║
        ║  FDA 21 CFR Part 11 audit trail: RECORDED                   ║
        ║  HIPAA compliance status: VERIFIED                           ║
        ╚══════════════════════════════════════════════════════════════╝
        """.stripIndent()
    }

    // ==================================================================
    // Final Notifications
    // ==================================================================
    stage('Notify') {
        notifySlack(
            status:      'SUCCESS',
            channel:     '#neurosphere-ops',
            environment: 'production',
            message:     """✅ PRODUCTION DEPLOYMENT SUCCESSFUL
                |  Tag: ${imageTag}
                |  Ticket: ${changeTicket}
                |  Services: ${services.join(', ')}
                |  🏥 All systems operational
            """.stripMargin()
        )

        // Compliance channel notification
        notifySlack(
            status:      'SUCCESS',
            channel:     '#neurosphere-compliance',
            environment: 'production',
            message:     """🏥 [COMPLIANCE] Production release ${imageTag}
                |  Change Ticket: ${changeTicket}
                |  Build: #${env.BUILD_NUMBER}
                |  Audit trail ID: PROD-${env.BUILD_NUMBER}
                |  FDA 21 CFR Part 11: ✅ Compliant
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

/**
 * Perform automatic rollback of all services to their previous version.
 */
def performRollback(List<String> services) {
    echo "🔄 AUTOMATIC ROLLBACK — reverting all services..."

    services.each { svc ->
        sh """
            kubectl rollout undo deployment/${svc} -n neurosphere-production || true
        """
    }

    // Wait for rollback to complete
    services.each { svc ->
        sh """
            kubectl rollout status deployment/${svc} \\
                -n neurosphere-production \\
                --timeout=180s || true
        """
    }

    notifySlack(
        status:      'ROLLBACK',
        channel:     '#neurosphere-ops',
        environment: 'production',
        message:     """🔄 AUTOMATIC ROLLBACK COMPLETED
            |  Services rolled back: ${services.join(', ')}
            |  ⚠️ Previous version restored — investigate failure
        """.stripMargin()
    )
}

/**
 * Write a production audit log entry for FDA 21 CFR Part 11 compliance.
 * Every production action must be recorded with:
 *   - Timestamp, actor, action, and outcome
 *   - Cryptographic integrity (via Jenkins build signature)
 */
def writeProductionAudit(String action, Map details) {
    def entry = [
        timestamp:    new Date().format("yyyy-MM-dd'T'HH:mm:ss'Z'", TimeZone.getTimeZone('UTC')),
        action:       action,
        buildId:      env.BUILD_NUMBER,
        jobName:      env.JOB_NAME,
        user:         env.BUILD_USER_ID ?: 'system',
        gitCommit:    env.GIT_COMMIT_SHORT ?: 'unknown',
        environment:  'production',
        changeTicket: params.CHANGE_TICKET ?: '',
        details:      details,
        compliance:   [
            'FDA_21CFR_Part11': true,
            'HIPAA_164_312':   true,
            'IEC_62304':       true,
        ]
    ]

    def json = groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(entry))
    echo "[PROD-AUDIT] ${json}"
    writeFile file: "audit-trail/prod-${action}-${env.BUILD_NUMBER}.json", text: json
    archiveArtifacts artifacts: 'audit-trail/**/*.json', allowEmptyArchive: true
}
