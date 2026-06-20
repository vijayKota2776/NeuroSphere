#!/usr/bin/env groovy
/**
 * neurospherePipeline.groovy
 * NeuroSphere Medical Robotics — Shared Library
 *
 * Standardized pipeline wrapper that enforces consistent:
 *   - Environment configuration
 *   - Error handling & notifications
 *   - Timestamps, build metadata, and audit trails
 *   - Healthcare regulatory compliance (HIPAA / FDA 21 CFR Part 11)
 *
 * Usage:
 *   neurospherePipeline(serviceName: 'vital-sign-aggregator', deployTarget: 'dev') {
 *       stage('Build') { ... }
 *   }
 */

def call(Map config = [:], Closure body) {
    // ---------------------------------------------------------------
    // Default configuration
    // ---------------------------------------------------------------
    def serviceName    = config.get('serviceName', env.JOB_BASE_NAME ?: 'unknown-service')
    def dockerfilePath = config.get('dockerfilePath', "services/${serviceName}/Dockerfile")
    def testCommand    = config.get('testCommand', 'make test')
    def deployTarget   = config.get('deployTarget', 'dev')
    def timeout_min    = config.get('timeoutMinutes', 30)
    def enableAudit    = config.get('enableAuditLog', true)

    // ---------------------------------------------------------------
    // Pipeline options
    // ---------------------------------------------------------------
    pipeline {
        agent any

        options {
            timestamps()
            timeout(time: timeout_min, unit: 'MINUTES')
            buildDiscarder(logRotator(numToKeepStr: '25', artifactNumToKeepStr: '10'))
            disableConcurrentBuilds()
            ansiColor('xterm')
        }

        environment {
            // Standard NeuroSphere build environment
            NEUROSPHERE_SERVICE   = "${serviceName}"
            NEUROSPHERE_ENV       = "${deployTarget}"
            DOCKER_REGISTRY       = credentials('neurosphere-docker-registry-url')
            BUILD_TIMESTAMP       = sh(script: 'date -u +"%Y-%m-%dT%H:%M:%SZ"', returnStdout: true).trim()
            GIT_COMMIT_SHORT      = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
            GIT_AUTHOR            = sh(script: 'git log -1 --format="%an"', returnStdout: true).trim()
            IMAGE_TAG             = "${env.GIT_COMMIT_SHORT}-${env.BUILD_NUMBER}"
            // Healthcare compliance
            HIPAA_COMPLIANT       = 'true'
            AUDIT_TRAIL_ENABLED   = "${enableAudit}"
            FDA_21CFR_PART11      = 'true'
        }

        stages {
            stage('Initialize') {
                steps {
                    script {
                        echo """
                        ╔══════════════════════════════════════════════════════════════╗
                        ║  NeuroSphere Medical Robotics — CI/CD Pipeline              ║
                        ║  Service : ${serviceName.padRight(48)}║
                        ║  Target  : ${deployTarget.padRight(48)}║
                        ║  Build   : #${env.BUILD_NUMBER.padRight(47)}║
                        ║  Commit  : ${env.GIT_COMMIT_SHORT.padRight(48)}║
                        ╚══════════════════════════════════════════════════════════════╝
                        """.stripIndent()

                        // Audit log entry — FDA 21 CFR Part 11 traceability
                        if (enableAudit) {
                            writeAuditEntry(
                                action:  'PIPELINE_STARTED',
                                service: serviceName,
                                env:     deployTarget,
                                user:    env.GIT_AUTHOR,
                                commit:  env.GIT_COMMIT_SHORT
                            )
                        }

                        currentBuild.displayName = "#${env.BUILD_NUMBER} — ${serviceName} → ${deployTarget}"
                        currentBuild.description = "Commit: ${env.GIT_COMMIT_SHORT} | Author: ${env.GIT_AUTHOR}"
                    }
                }
            }

            stage('Pipeline Body') {
                steps {
                    script {
                        body.call()
                    }
                }
            }
        }

        post {
            success {
                script {
                    if (enableAudit) {
                        writeAuditEntry(action: 'PIPELINE_SUCCESS', service: serviceName, env: deployTarget)
                    }
                    notifySlack(
                        status:      'SUCCESS',
                        channel:     channelForEnv(deployTarget),
                        environment: deployTarget,
                        buildUrl:    env.BUILD_URL,
                        message:     "✅ ${serviceName} pipeline succeeded (${deployTarget})"
                    )
                }
            }
            failure {
                script {
                    if (enableAudit) {
                        writeAuditEntry(action: 'PIPELINE_FAILURE', service: serviceName, env: deployTarget)
                    }
                    notifySlack(
                        status:      'FAILURE',
                        channel:     channelForEnv(deployTarget),
                        environment: deployTarget,
                        buildUrl:    env.BUILD_URL,
                        message:     "🔴 ${serviceName} pipeline FAILED (${deployTarget}) — immediate attention required"
                    )
                }
            }
            unstable {
                script {
                    notifySlack(
                        status:      'UNSTABLE',
                        channel:     channelForEnv(deployTarget),
                        environment: deployTarget,
                        buildUrl:    env.BUILD_URL,
                        message:     "⚠️ ${serviceName} pipeline unstable (${deployTarget}) — review test results"
                    )
                }
            }
            always {
                cleanWs()
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/**
 * Map deploy target to the appropriate Slack channel.
 */
private String channelForEnv(String env) {
    def channels = [
        'dev'       : '#neurosphere-dev',
        'staging'   : '#neurosphere-qa',
        'production': '#neurosphere-ops',
        'prod'      : '#neurosphere-ops',
    ]
    return channels.getOrDefault(env, '#neurosphere-dev')
}

/**
 * Write a structured audit log entry.
 * Required for FDA 21 CFR Part 11 and HIPAA compliance.
 */
private void writeAuditEntry(Map params) {
    def entry = [
        timestamp: new Date().format("yyyy-MM-dd'T'HH:mm:ss'Z'", TimeZone.getTimeZone('UTC')),
        action:    params.action,
        service:   params.get('service', 'unknown'),
        env:       params.get('env', 'unknown'),
        user:      params.get('user', env.BUILD_USER_ID ?: 'system'),
        commit:    params.get('commit', env.GIT_COMMIT_SHORT ?: 'n/a'),
        buildId:   env.BUILD_NUMBER,
        jobName:   env.JOB_NAME,
    ]
    def json = groovy.json.JsonOutput.toJson(entry)
    echo "[AUDIT] ${json}"
    // Persist to workspace for archival by compliance tools
    writeFile file: "audit-trail/${params.action}-${env.BUILD_NUMBER}.json", text: groovy.json.JsonOutput.prettyPrint(json)
    archiveArtifacts artifacts: 'audit-trail/**/*.json', allowEmptyArchive: true
}
