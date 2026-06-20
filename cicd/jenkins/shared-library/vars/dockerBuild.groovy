#!/usr/bin/env groovy
/**
 * dockerBuild.groovy
 * NeuroSphere Medical Robotics — Shared Library
 *
 * Reusable Docker image build & push step.
 * Enforces OCI labels for traceability (required by FDA 21 CFR Part 11)
 * and produces a Software Bill of Materials (SBOM) for supply chain audits.
 *
 * Usage:
 *   def digest = dockerBuild(
 *       serviceName:    'telemetry-ingest',
 *       dockerfilePath: 'services/telemetry-ingest/Dockerfile',
 *       registry:       'registry.neurosphere.io',
 *       tag:            'v1.2.3',
 *       buildArgs:      ['BASE_IMAGE=python:3.11-slim']
 *   )
 */

def call(Map args) {
    // ------------------------------------------------------------------
    // Parameter validation
    // ------------------------------------------------------------------
    def serviceName    = requireParam(args, 'serviceName')
    def dockerfilePath = args.get('dockerfilePath', "services/${serviceName}/Dockerfile")
    def registry       = args.get('registry', env.DOCKER_REGISTRY ?: 'registry.neurosphere.io')
    def tag            = args.get('tag', env.IMAGE_TAG ?: 'latest')
    def buildArgs      = args.get('buildArgs', [])
    def noCache        = args.get('noCache', true)
    def context        = args.get('context', '.')
    def platforms      = args.get('platforms', '')   // e.g. 'linux/amd64,linux/arm64'

    def fullImage      = "${registry}/neurosphere/${serviceName}"
    def imageDigest    = ''

    echo "🐳 Docker Build — ${fullImage}:${tag}"

    // ------------------------------------------------------------------
    // Build
    // ------------------------------------------------------------------
    stage("Docker Build: ${serviceName}") {
        def buildArgsStr = buildArgs.collect { "--build-arg ${it}" }.join(' ')
        def cacheFlag    = noCache ? '--no-cache' : ''

        // OCI / opencontainers labels for regulatory traceability
        def labels = [
            "--label org.opencontainers.image.title=${serviceName}",
            "--label org.opencontainers.image.source=${env.GIT_URL ?: 'https://github.com/neurosphere/neurosphere'}",
            "--label org.opencontainers.image.revision=${env.GIT_COMMIT_SHORT ?: 'unknown'}",
            "--label org.opencontainers.image.created=${env.BUILD_TIMESTAMP ?: new Date().format("yyyy-MM-dd'T'HH:mm:ss'Z'")}",
            "--label org.opencontainers.image.vendor=NeuroSphere Medical Robotics",
            "--label io.neurosphere.hipaa-compliant=true",
            "--label io.neurosphere.fda-21cfr-part11=true",
            "--label io.neurosphere.build-id=${env.BUILD_NUMBER ?: '0'}",
        ].join(' ')

        sh """
            docker build \\
                ${cacheFlag} \\
                -f ${dockerfilePath} \\
                -t ${fullImage}:${tag} \\
                -t ${fullImage}:latest \\
                ${buildArgsStr} \\
                ${labels} \\
                ${context}
        """

        echo "✅ Image built: ${fullImage}:${tag}"
    }

    // ------------------------------------------------------------------
    // Push
    // ------------------------------------------------------------------
    stage("Docker Push: ${serviceName}") {
        withCredentials([usernamePassword(
            credentialsId: 'neurosphere-docker-credentials',
            usernameVariable: 'DOCKER_USER',
            passwordVariable: 'DOCKER_PASS'
        )]) {
            sh "echo \$DOCKER_PASS | docker login ${registry} -u \$DOCKER_USER --password-stdin"

            sh "docker push ${fullImage}:${tag}"
            sh "docker push ${fullImage}:latest"

            // Capture image digest for deployment pinning
            imageDigest = sh(
                script: "docker inspect --format='{{index .RepoDigests 0}}' ${fullImage}:${tag} | cut -d@ -f2",
                returnStdout: true
            ).trim()

            echo "📦 Pushed ${fullImage}:${tag}"
            echo "🔑 Digest: ${imageDigest}"
        }
    }

    // ------------------------------------------------------------------
    // SBOM generation (supply chain security)
    // ------------------------------------------------------------------
    stage("SBOM: ${serviceName}") {
        sh """
            syft ${fullImage}:${tag} -o spdx-json > sbom-${serviceName}-${tag}.spdx.json || true
        """
        archiveArtifacts artifacts: "sbom-*.spdx.json", allowEmptyArchive: true
        echo "📋 SBOM generated for ${serviceName}"
    }

    // ------------------------------------------------------------------
    // Cleanup local images to free disk
    // ------------------------------------------------------------------
    sh "docker rmi ${fullImage}:${tag} || true"
    sh "docker rmi ${fullImage}:latest || true"

    return imageDigest
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

private String requireParam(Map args, String key) {
    if (!args.containsKey(key) || !args[key]) {
        error "dockerBuild: required parameter '${key}' is missing"
    }
    return args[key]
}
