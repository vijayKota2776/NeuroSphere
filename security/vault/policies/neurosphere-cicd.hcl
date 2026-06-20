# =============================================================================
# NeuroSphere Vault Policy: CI/CD Pipeline
# =============================================================================
# Access policy for CI/CD pipelines (GitHub Actions, ArgoCD, Jenkins, etc.)
# used to build, test, and deploy NeuroSphere microservices.
#
# This policy grants read-only access to:
#   - CI/CD pipeline configuration secrets
#   - Docker/OCI registry credentials (ECR push/pull)
#   - Source control and code quality tool API keys
#
# SECURITY NOTES:
#   - CI/CD tokens should have short TTLs (max 1 hour for pipeline runs)
#   - Pipeline auth uses Kubernetes auth or AppRole with SecretID wrapping
#   - All pipeline secret access is audit-logged for SOC 2 compliance
#   - Docker registry credentials are rotated via AWS STS assume-role
#
# IEC 62304 §8.1.1: Software configuration management — CI/CD pipelines
# must use authenticated, audited access to build artifacts and credentials.
# =============================================================================

# ---------------------------------------------------------------------------
# CI/CD Pipeline Secrets
# ---------------------------------------------------------------------------
# Pipeline configuration: build parameters, deployment targets, feature
# flags, environment-specific configuration, notification webhooks.
path "neurosphere/data/cicd/*" {
  capabilities = ["read"]
}

# ---------------------------------------------------------------------------
# Docker / OCI Registry Credentials
# ---------------------------------------------------------------------------
# Container registry authentication for pushing and pulling NeuroSphere
# service images. Supports AWS ECR, Harbor, or other OCI-compliant registries.
path "neurosphere/data/docker-registry/*" {
  capabilities = ["read"]
}

# ---------------------------------------------------------------------------
# GitHub API Token
# ---------------------------------------------------------------------------
# Personal access token or GitHub App installation token for:
#   - Source code checkout in pipelines
#   - Pull request status checks
#   - Release artifact publishing
#   - Dependency vulnerability scanning (Dependabot)
path "neurosphere/data/api-keys/github" {
  capabilities = ["read"]
}

# ---------------------------------------------------------------------------
# SonarQube API Token
# ---------------------------------------------------------------------------
# Authentication for static code analysis and quality gate enforcement.
# SonarQube scans are mandatory for all NeuroSphere services before
# deployment to staging/production environments.
#
# IEC 62304 §5.5.3: Software unit verification — static analysis is
# required for Class B and Class C medical device software.
path "neurosphere/data/api-keys/sonarqube" {
  capabilities = ["read"]
}
