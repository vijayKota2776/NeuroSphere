/**
 * seed-job.groovy
 * NeuroSphere Medical Robotics — Job DSL Seed Job
 *
 * This is the master seed job that generates the complete CI/CD job
 * hierarchy for the NeuroSphere platform. It creates:
 *   1. Top-level folder structure
 *   2. Multibranch pipeline for the main repository
 *   3. Environment-specific deployment jobs (dev, staging, prod)
 *   4. Utility jobs (cleanup, security audits)
 *
 * Healthcare Compliance:
 *   - All jobs include audit trail configuration
 *   - Production jobs require approval workflows
 *   - FDA 21 CFR Part 11 traceability is enforced
 *
 * Run this seed job to regenerate all downstream jobs.
 */

// =====================================================================
// 1. Folder Structure
// =====================================================================

folder('NeuroSphere') {
    displayName('NeuroSphere Medical Robotics')
    description('''
        CI/CD pipelines for the NeuroSphere Medical Robotics platform.
        Includes build, test, security scan, and deployment jobs
        for all microservices.

        ⚕️ All pipelines comply with:
        • HIPAA Security Rule § 164.312
        • FDA 21 CFR Part 11 (Electronic Records)
        • IEC 62304 (Medical Device Software Lifecycle)
    '''.stripIndent())
}

folder('NeuroSphere/Build') {
    displayName('Build Pipelines')
    description('Continuous Integration — build, test, and scan all services')
}

folder('NeuroSphere/Deploy') {
    displayName('Deployment Pipelines')
    description('Continuous Deployment — deploy to dev, staging, and production')
}

folder('NeuroSphere/Utilities') {
    displayName('Utility Jobs')
    description('Maintenance, cleanup, and audit jobs')
}

// =====================================================================
// 2. Multibranch Pipeline — Main Repository
// =====================================================================

multibranchPipelineJob('NeuroSphere/Build/neurosphere-main') {
    displayName('NeuroSphere — Main Build')
    description('Multibranch pipeline for the neurosphere monorepo. Discovers branches and PRs automatically.')

    branchSources {
        github {
            id('neurosphere-github-source')
            repoOwner('neurosphere')
            repository('neurosphere')
            credentialsId('neurosphere-github-token')

            buildForkPRMerge(true)
            buildOriginBranch(true)
            buildOriginBranchWithPR(false)
            buildOriginPRMerge(true)
        }
    }

    factory {
        workflowBranchProjectFactory {
            scriptPath('Jenkinsfile')
        }
    }

    orphanedItemStrategy {
        discardOldItems {
            numToKeep(20)
            daysToKeep(30)
        }
    }

    triggers {
        periodicFolderTrigger {
            interval('5 minutes')
        }
    }

    properties {
        suppressFolderAutomaticTriggering {
            branches('main|develop|release/.*')
            strategy('INDEXING')
        }
    }

    configure { node ->
        // Healthcare compliance: enable build retention for audit
        def traits = node / sources / data / 'jenkins.branch.BranchSource' / source / traits
        traits << 'jenkins.plugins.git.traits.CloneOptionTrait' {
            extension {
                shallow(false)
                noTags(false)
                timeout(30)
            }
        }
    }
}

// =====================================================================
// 3. Per-Service Build Pipelines
// =====================================================================

def services = [
    [name: 'telemetry-ingest',       lang: 'python',  tier: 'data'],
    [name: 'vital-sign-aggregator',  lang: 'python',  tier: 'data'],
    [name: 'diagnostic-engine',      lang: 'python',  tier: 'core'],
    [name: 'robotic-control-api',    lang: 'python',  tier: 'core'],
    [name: 'patient-gateway',        lang: 'node',    tier: 'api'],
    [name: 'surgeon-dashboard',      lang: 'node',    tier: 'frontend'],
    [name: 'compliance-auditor',     lang: 'python',  tier: 'platform'],
    [name: 'alert-dispatcher',       lang: 'python',  tier: 'platform'],
]

services.each { svc ->
    pipelineJob("NeuroSphere/Build/${svc.name}") {
        displayName("Build: ${svc.name}")
        description("CI pipeline for ${svc.name} (${svc.lang}, tier: ${svc.tier})")

        logRotator {
            numToKeep(30)
            artifactNumToKeep(10)
        }

        parameters {
            stringParam('BRANCH', 'develop', 'Git branch to build')
            stringParam('IMAGE_TAG', '', 'Override image tag (default: auto-generated)')
            booleanParam('SKIP_TESTS', false, 'Skip test execution (NOT recommended for medical software)')
            booleanParam('SKIP_SECURITY_SCAN', false, 'Skip Trivy security scan')
        }

        definition {
            cpsScm {
                scm {
                    git {
                        remote {
                            url('https://github.com/neurosphere/neurosphere.git')
                            credentials('neurosphere-github-token')
                        }
                        branches('${BRANCH}')
                    }
                }
                scriptPath("services/${svc.name}/Jenkinsfile")
            }
        }

        triggers {
            scm('H/5 * * * *')
        }
    }
}

// =====================================================================
// 4. Deployment Jobs (delegates to individual DSL scripts)
// =====================================================================

pipelineJob('NeuroSphere/Deploy/deploy-dev') {
    displayName('Deploy → Development')
    description('Auto-deploys to development environment on develop branch changes.')

    logRotator {
        numToKeep(50)
    }

    parameters {
        stringParam('IMAGE_TAG', '', 'Image tag to deploy (leave empty for latest develop build)')
        stringParam('SERVICES', '', 'Comma-separated list of services to deploy (empty = all)')
    }

    definition {
        cpsScm {
            scm {
                git {
                    remote {
                        url('https://github.com/neurosphere/neurosphere.git')
                        credentials('neurosphere-github-token')
                    }
                    branches('develop')
                }
            }
            scriptPath('cicd/jenkins/jobs/deploy-dev.groovy')
        }
    }

    triggers {
        upstream('NeuroSphere/Build/neurosphere-main/develop', 'SUCCESS')
    }
}

pipelineJob('NeuroSphere/Deploy/deploy-staging') {
    displayName('Deploy → Staging')
    description('Deploys to staging on release branch changes with full test suite.')

    logRotator {
        numToKeep(50)
    }

    parameters {
        stringParam('IMAGE_TAG', '', 'Image tag to deploy')
        stringParam('SERVICES', '', 'Comma-separated list of services')
        booleanParam('RUN_INTEGRATION_TESTS', true, 'Run full integration test suite')
    }

    definition {
        cpsScm {
            scm {
                git {
                    remote {
                        url('https://github.com/neurosphere/neurosphere.git')
                        credentials('neurosphere-github-token')
                    }
                    branches('release/*')
                }
            }
            scriptPath('cicd/jenkins/jobs/deploy-staging.groovy')
        }
    }
}

pipelineJob('NeuroSphere/Deploy/deploy-prod') {
    displayName('Deploy → Production 🏥')
    description('''
        Production deployment with blue/green strategy.
        ⚠️ Requires dual approval (Engineering Lead + Ops).
        Includes automatic rollback and compliance audit logging.
    '''.stripIndent())

    logRotator {
        numToKeep(100)
        artifactNumToKeep(50)
    }

    parameters {
        stringParam('IMAGE_TAG', '', 'Image tag to deploy (REQUIRED)')
        stringParam('SERVICES', '', 'Comma-separated list of services')
        booleanParam('DRY_RUN', false, 'Validate deployment without applying changes')
        stringParam('CHANGE_TICKET', '', 'Change management ticket number (e.g., CHG-2026-0142)')
    }

    definition {
        cpsScm {
            scm {
                git {
                    remote {
                        url('https://github.com/neurosphere/neurosphere.git')
                        credentials('neurosphere-github-token')
                    }
                    branches('main')
                }
            }
            scriptPath('cicd/jenkins/jobs/deploy-prod.groovy')
        }
    }

    // Production — manual trigger only, no automatic triggers
}

// =====================================================================
// 5. Utility Jobs
// =====================================================================

pipelineJob('NeuroSphere/Utilities/security-audit') {
    displayName('Full Security Audit')
    description('Runs comprehensive security scan across all service images.')

    logRotator { numToKeep(30) }

    triggers {
        cron('H 2 * * 1')   // Weekly on Monday at ~2 AM
    }

    definition {
        cps {
            script('''
                @Library('neurosphere-shared-lib') _

                pipeline {
                    agent any
                    stages {
                        stage('Audit All Images') {
                            steps {
                                script {
                                    def services = ['telemetry-ingest', 'vital-sign-aggregator',
                                                    'diagnostic-engine', 'robotic-control-api',
                                                    'patient-gateway', 'surgeon-dashboard',
                                                    'compliance-auditor', 'alert-dispatcher']
                                    services.each { svc ->
                                        securityScan(
                                            imageName: "registry.neurosphere.io/neurosphere/${svc}:latest",
                                            severityThreshold: 'MEDIUM',
                                            exitOnFailure: false
                                        )
                                    }
                                }
                            }
                        }
                    }
                    post {
                        always {
                            notifySlack(
                                status: currentBuild.result ?: 'SUCCESS',
                                channel: '#neurosphere-security',
                                environment: 'audit',
                                message: "🔒 Weekly security audit complete"
                            )
                        }
                    }
                }
            '''.stripIndent())
            sandbox()
        }
    }
}

pipelineJob('NeuroSphere/Utilities/workspace-cleanup') {
    displayName('Workspace Cleanup')
    description('Cleans up old workspaces, Docker images, and build artifacts.')

    logRotator { numToKeep(10) }

    triggers {
        cron('H 4 * * 0')   // Weekly on Sunday at ~4 AM
    }

    definition {
        cps {
            script('''
                pipeline {
                    agent any
                    stages {
                        stage('Cleanup') {
                            steps {
                                sh 'docker system prune -af --filter "until=168h" || true'
                                sh 'docker volume prune -f || true'
                                cleanWs()
                            }
                        }
                    }
                }
            '''.stripIndent())
            sandbox()
        }
    }
}

// =====================================================================
// 6. Views
// =====================================================================

listView('NeuroSphere/All Builds') {
    jobs {
        regex('NeuroSphere/Build/.*')
    }
    columns {
        status()
        weather()
        name()
        lastSuccess()
        lastFailure()
        lastDuration()
        buildButton()
    }
}

listView('NeuroSphere/Deployments') {
    jobs {
        regex('NeuroSphere/Deploy/.*')
    }
    columns {
        status()
        weather()
        name()
        lastSuccess()
        lastFailure()
        lastDuration()
        buildButton()
    }
}
