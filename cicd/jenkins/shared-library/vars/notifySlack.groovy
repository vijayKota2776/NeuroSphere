#!/usr/bin/env groovy
/**
 * notifySlack.groovy
 * NeuroSphere Medical Robotics — Shared Library
 *
 * Sends color-coded Slack notifications with build metadata.
 * Channels are mapped by environment to ensure the right team
 * receives alerts (dev → engineering, staging → QA, prod → ops).
 *
 * Usage:
 *   notifySlack(
 *       status:      'SUCCESS',
 *       channel:     '#neurosphere-ops',
 *       environment: 'production',
 *       buildUrl:    env.BUILD_URL,
 *       message:     'Deployment complete'
 *   )
 */

def call(Map args) {
    def status      = args.get('status', 'INFO')
    def channel     = args.get('channel', '#neurosphere-dev')
    def environment = args.get('environment', 'unknown')
    def buildUrl    = args.get('buildUrl', env.BUILD_URL ?: '#')
    def message     = args.get('message', '')
    def mentions    = args.get('mentions', [])          // e.g. ['@oncall-eng']
    def service     = args.get('serviceName', env.NEUROSPHERE_SERVICE ?: env.JOB_BASE_NAME ?: 'unknown')
    def includeLog  = args.get('includeLog', false)

    // ------------------------------------------------------------------
    // Color mapping
    // ------------------------------------------------------------------
    def colorMap = [
        'SUCCESS'  : '#2ECC71',   // Green
        'FAILURE'  : '#E74C3C',   // Red
        'UNSTABLE' : '#F39C12',   // Yellow / Amber
        'ABORTED'  : '#95A5A6',   // Grey
        'STARTED'  : '#3498DB',   // Blue
        'INFO'     : '#3498DB',   // Blue
        'ROLLBACK' : '#E74C3C',   // Red
        'APPROVED' : '#2ECC71',   // Green
    ]
    def color = colorMap.getOrDefault(status.toUpperCase(), '#3498DB')

    // ------------------------------------------------------------------
    // Emoji mapping
    // ------------------------------------------------------------------
    def emojiMap = [
        'SUCCESS'  : '✅',
        'FAILURE'  : '🔴',
        'UNSTABLE' : '⚠️',
        'ABORTED'  : '⛔',
        'STARTED'  : '🚀',
        'INFO'     : 'ℹ️',
        'ROLLBACK' : '🔄',
        'APPROVED' : '👍',
    ]
    def emoji = emojiMap.getOrDefault(status.toUpperCase(), 'ℹ️')

    // ------------------------------------------------------------------
    // Build healthcare-context message
    // ------------------------------------------------------------------
    def commitSha  = env.GIT_COMMIT_SHORT ?: sh(script: 'git rev-parse --short HEAD 2>/dev/null || echo "n/a"', returnStdout: true).trim()
    def branch     = env.BRANCH_NAME ?: env.GIT_BRANCH ?: 'unknown'
    def buildUser  = env.BUILD_USER_ID ?: 'automated'

    def headerText = message ?: "${emoji} ${statusLabel(status)} — ${service}"

    def attachments = [
        [
            color:    color,
            fallback: headerText,
            blocks:   [
                [
                    type: 'header',
                    text: [type: 'plain_text', text: headerText, emoji: true]
                ],
                [
                    type: 'section',
                    fields: [
                        [type: 'mrkdwn', text: "*Service:*\n${service}"],
                        [type: 'mrkdwn', text: "*Environment:*\n${environment}"],
                        [type: 'mrkdwn', text: "*Branch:*\n`${branch}`"],
                        [type: 'mrkdwn', text: "*Commit:*\n`${commitSha}`"],
                        [type: 'mrkdwn', text: "*Build:*\n<${buildUrl}|#${env.BUILD_NUMBER ?: '?'}>"],
                        [type: 'mrkdwn', text: "*Triggered by:*\n${buildUser}"],
                    ]
                ],
                [
                    type: 'context',
                    elements: [
                        [
                            type: 'mrkdwn',
                            text: "🏥 NeuroSphere Medical Robotics CI/CD • ${new Date().format('yyyy-MM-dd HH:mm:ss z')}"
                        ]
                    ]
                ]
            ]
        ]
    ]

    // ------------------------------------------------------------------
    // Add mentions for critical statuses
    // ------------------------------------------------------------------
    def mentionText = ''
    if (status.toUpperCase() in ['FAILURE', 'ROLLBACK']) {
        // Auto-mention on-call for production failures
        if (environment in ['production', 'prod']) {
            mentions = (mentions ?: []) + ['@neurosphere-oncall', '@neurosphere-ops']
        }
    }
    if (mentions) {
        mentionText = mentions.collect { it.startsWith('@') ? "<!subteam^${it}>" : it }.join(' ')
    }

    // ------------------------------------------------------------------
    // Send notification
    // ------------------------------------------------------------------
    try {
        slackSend(
            channel:     channel,
            color:       color,
            attachments: groovy.json.JsonOutput.toJson(attachments),
            message:     mentionText ? "${mentionText}\n${headerText}" : headerText,
            tokenCredentialId: 'neurosphere-slack-webhook'
        )
        echo "📨 Slack notification sent to ${channel} [${status}]"
    } catch (Exception e) {
        // Slack failures should never break the pipeline
        echo "⚠️ Slack notification failed (non-fatal): ${e.message}"
    }

    // ------------------------------------------------------------------
    // For production deployments, also post to the compliance channel
    // ------------------------------------------------------------------
    if (environment in ['production', 'prod'] && status.toUpperCase() in ['SUCCESS', 'FAILURE', 'ROLLBACK']) {
        try {
            slackSend(
                channel:           '#neurosphere-compliance',
                color:             color,
                message:           "🏥 [COMPLIANCE] ${headerText}\nEnvironment: ${environment} | Commit: ${commitSha} | Build: #${env.BUILD_NUMBER}",
                tokenCredentialId: 'neurosphere-slack-webhook'
            )
        } catch (Exception ignored) {
            // Non-fatal
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Human-friendly status labels with healthcare context.
 */
private String statusLabel(String status) {
    def labels = [
        'SUCCESS'  : 'Pipeline Succeeded',
        'FAILURE'  : 'Pipeline FAILED — Action Required',
        'UNSTABLE' : 'Pipeline Unstable — Review Needed',
        'ABORTED'  : 'Pipeline Aborted',
        'STARTED'  : 'Pipeline Started',
        'INFO'     : 'Pipeline Update',
        'ROLLBACK' : 'ROLLBACK Triggered — Previous Version Restored',
        'APPROVED' : 'Deployment Approved',
    ]
    return labels.getOrDefault(status.toUpperCase(), status)
}
