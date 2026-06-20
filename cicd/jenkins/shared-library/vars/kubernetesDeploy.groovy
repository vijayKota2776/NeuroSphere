#!/usr/bin/env groovy
/**
 * kubernetesDeploy.groovy
 * NeuroSphere Medical Robotics — Shared Library
 *
 * Reusable Kubernetes deployment step using Kustomize overlays.
 * Supports:
 *   - Dry-run mode for validation
 *   - Rollout status verification with configurable timeout
 *   - Automatic rollback on failure
 *   - Healthcare audit trail entries
 *
 * Usage:
 *   def status = kubernetesDeploy(
 *       environment:   'staging',
 *       namespace:     'neurosphere-staging',
 *       kustomizePath: 'k8s/overlays/staging',
 *       imageTag:      'abc1234-42',
 *       services:      ['telemetry-ingest', 'vital-sign-aggregator']
 *   )
 */

def call(Map args) {
    // ------------------------------------------------------------------
    // Parameters
    // ------------------------------------------------------------------
    def environment    = requireParam(args, 'environment')
    def namespace      = args.get('namespace', "neurosphere-${environment}")
    def kustomizePath  = args.get('kustomizePath', "k8s/overlays/${environment}")
    def imageTag       = requireParam(args, 'imageTag')
    def services       = args.get('services', [])
    def dryRun         = args.get('dryRun', false)
    def rolloutTimeout = args.get('rolloutTimeout', 300)       // seconds
    def registry       = args.get('registry', env.DOCKER_REGISTRY ?: 'registry.neurosphere.io')
    def kubeContext    = args.get('kubeContext', "neurosphere-${environment}")
    def enableAudit    = args.get('enableAuditLog', true)

    def deployStatus   = 'UNKNOWN'

    echo """
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     Kubernetes Deploy — NeuroSphere
     Environment : ${environment}
     Namespace   : ${namespace}
     Image Tag   : ${imageTag}
     Services    : ${services.join(', ') ?: 'all'}
     Dry Run     : ${dryRun}
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    """.stripIndent()

    // ------------------------------------------------------------------
    // Validate prerequisites
    // ------------------------------------------------------------------
    stage("Pre-Deploy Validation: ${environment}") {
        sh "kubectl config use-context ${kubeContext}"
        sh "kubectl get namespace ${namespace} || kubectl create namespace ${namespace}"

        // Ensure kustomize overlay exists
        if (!fileExists(kustomizePath)) {
            error "Kustomize overlay not found: ${kustomizePath}"
        }
    }

    // ------------------------------------------------------------------
    // Set image tags via kustomize
    // ------------------------------------------------------------------
    stage("Kustomize Image Tags: ${environment}") {
        dir(kustomizePath) {
            if (services) {
                services.each { svc ->
                    def fullImage = "${registry}/neurosphere/${svc}"
                    sh "kustomize edit set image ${fullImage}=${fullImage}:${imageTag}"
                    echo "  → ${svc} ➜ ${fullImage}:${imageTag}"
                }
            } else {
                // If no services specified, set a generic image tag
                sh "kustomize edit set image neurosphere/*=neurosphere/*:${imageTag}"
            }
        }
    }

    // ------------------------------------------------------------------
    // Render & validate manifests
    // ------------------------------------------------------------------
    stage("Manifest Validation: ${environment}") {
        sh "kustomize build ${kustomizePath} > rendered-manifests-${environment}.yaml"
        sh "kubectl apply --dry-run=client -f rendered-manifests-${environment}.yaml -n ${namespace}"
        archiveArtifacts artifacts: "rendered-manifests-${environment}.yaml", allowEmptyArchive: true
        echo "✅ Manifests validated successfully"
    }

    // ------------------------------------------------------------------
    // Apply (or dry-run)
    // ------------------------------------------------------------------
    if (dryRun) {
        stage("Dry Run: ${environment}") {
            sh "kubectl apply --dry-run=server -f rendered-manifests-${environment}.yaml -n ${namespace}"
            echo "🔍 Dry run complete — no changes applied"
            deployStatus = 'DRY_RUN_OK'
        }
    } else {
        stage("Apply: ${environment}") {
            try {
                sh "kubectl apply -f rendered-manifests-${environment}.yaml -n ${namespace}"
                echo "📦 Manifests applied to ${namespace}"
            } catch (Exception e) {
                deployStatus = 'APPLY_FAILED'
                error "kubectl apply failed: ${e.message}"
            }
        }

        // ------------------------------------------------------------------
        // Rollout verification
        // ------------------------------------------------------------------
        stage("Rollout Verification: ${environment}") {
            def deployments = services ?: discoverDeployments(namespace)

            def failures = []
            deployments.each { dep ->
                try {
                    sh """
                        kubectl rollout status deployment/${dep} \\
                            -n ${namespace} \\
                            --timeout=${rolloutTimeout}s
                    """
                    echo "  ✅ ${dep} — rollout complete"
                } catch (Exception e) {
                    echo "  ❌ ${dep} — rollout FAILED"
                    failures << dep
                }
            }

            if (failures) {
                deployStatus = 'ROLLOUT_FAILED'

                // Automatic rollback for failed deployments
                echo "⚠️ Rolling back failed deployments: ${failures.join(', ')}"
                failures.each { dep ->
                    sh "kubectl rollout undo deployment/${dep} -n ${namespace} || true"
                }

                if (enableAudit) {
                    writeDeployAudit(
                        action:      'DEPLOY_ROLLBACK',
                        environment: environment,
                        services:    failures,
                        imageTag:    imageTag,
                        reason:      'Rollout timeout exceeded'
                    )
                }

                error "Rollout failed for: ${failures.join(', ')} — automatic rollback triggered"
            } else {
                deployStatus = 'SUCCESS'
                echo "✅ All deployments rolled out successfully in ${namespace}"
            }
        }

        // ------------------------------------------------------------------
        // Post-deploy health check
        // ------------------------------------------------------------------
        stage("Post-Deploy Health Check: ${environment}") {
            // Wait for pods to stabilize
            sleep(time: 15, unit: 'SECONDS')

            sh """
                kubectl get pods -n ${namespace} \\
                    -l app.kubernetes.io/part-of=neurosphere \\
                    -o wide
            """

            // Check for CrashLoopBackOff or Error states
            def unhealthy = sh(
                script: """
                    kubectl get pods -n ${namespace} \\
                        -l app.kubernetes.io/part-of=neurosphere \\
                        --field-selector=status.phase!=Running,status.phase!=Succeeded \\
                        -o name 2>/dev/null | wc -l
                """,
                returnStdout: true
            ).trim().toInteger()

            if (unhealthy > 0) {
                echo "⚠️ ${unhealthy} pod(s) in unhealthy state — review required"
                deployStatus = 'UNSTABLE'
            }
        }
    }

    // ------------------------------------------------------------------
    // Audit trail entry
    // ------------------------------------------------------------------
    if (enableAudit && !dryRun) {
        writeDeployAudit(
            action:      'DEPLOY_COMPLETE',
            environment: environment,
            services:    services,
            imageTag:    imageTag,
            status:      deployStatus
        )
    }

    return deployStatus
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

private String requireParam(Map args, String key) {
    if (!args.containsKey(key) || !args[key]) {
        error "kubernetesDeploy: required parameter '${key}' is missing"
    }
    return args[key]
}

/**
 * Discover deployments in a namespace by label selector.
 */
private List<String> discoverDeployments(String namespace) {
    def output = sh(
        script: """
            kubectl get deployments -n ${namespace} \\
                -l app.kubernetes.io/part-of=neurosphere \\
                -o jsonpath='{.items[*].metadata.name}'
        """,
        returnStdout: true
    ).trim()
    return output ? output.split(/\s+/).toList() : []
}

/**
 * Write a deployment audit log entry for compliance.
 * FDA 21 CFR Part 11 requires a complete audit trail of all
 * software deployments in medical device environments.
 */
private void writeDeployAudit(Map params) {
    def entry = [
        timestamp:   new Date().format("yyyy-MM-dd'T'HH:mm:ss'Z'", TimeZone.getTimeZone('UTC')),
        action:      params.action,
        environment: params.environment,
        services:    params.services,
        imageTag:    params.imageTag,
        status:      params.get('status', 'N/A'),
        reason:      params.get('reason', ''),
        buildId:     env.BUILD_NUMBER,
        user:        env.BUILD_USER_ID ?: 'system',
        commit:      env.GIT_COMMIT_SHORT ?: 'unknown',
    ]
    def json = groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(entry))
    echo "[DEPLOY-AUDIT] ${json}"
    writeFile file: "audit-trail/deploy-${params.action}-${env.BUILD_NUMBER}.json", text: json
    archiveArtifacts artifacts: 'audit-trail/**/*.json', allowEmptyArchive: true
}
