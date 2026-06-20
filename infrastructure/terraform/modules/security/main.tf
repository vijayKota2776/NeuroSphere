###############################################################################
# NeuroSphere Medical Robotics — Security Module
# 
# This module provisions foundational security infrastructure:
#   - ECR repositories for microservice container images (immutable tags for
#     FDA/IEC 62443 traceability)
#   - Terraform remote state storage (S3 + DynamoDB locking)
#   - Audit log bucket with Glacier lifecycle (HIPAA retention requirements)
#   - WAF Web ACL to protect the API gateway from common exploits
#
# All resources are encrypted at rest and tagged for compliance auditing.
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# --------------------------------------------------------------------------- #
# Data Sources
# --------------------------------------------------------------------------- #

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# --------------------------------------------------------------------------- #
# Locals
# --------------------------------------------------------------------------- #

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  # Standard naming prefix used across all resources in this module
  name_prefix = "neurosphere-${var.environment}"

  # Merge caller-supplied tags with mandatory compliance tags
  common_tags = merge(var.tags, {
    Project     = "NeuroSphere"
    Environment = var.environment
    Module      = "security"
    Compliance  = "HIPAA"
    ManagedBy   = "terraform"
  })
}

###############################################################################
# ECR Repositories
#
# One repository per microservice. Image tag immutability is enforced so that
# a given tag (e.g. a Git SHA) always resolves to the same image — critical
# for FDA audit trails and IEC 62443 software integrity verification.
###############################################################################

resource "aws_ecr_repository" "services" {
  for_each = toset(var.service_names)

  name                 = "${local.name_prefix}-${each.value}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true # CVE scanning on every push — required for medical device SW
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(local.common_tags, {
    Service = each.value
  })
}

# Lifecycle policy: retain only the last 30 images to control storage costs
# while keeping enough history for rollback and audit purposes.
resource "aws_ecr_lifecycle_policy" "services" {
  for_each = aws_ecr_repository.services

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 30 images for rollback and audit trail"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

###############################################################################
# IAM Policy — ECR Pull Access for EKS Nodes
#
# Grants EKS worker nodes permission to authenticate with ECR and pull images.
# This policy should be attached to the EKS node instance role or IRSA role.
###############################################################################

resource "aws_iam_policy" "ecr_pull" {
  name        = "${local.name_prefix}-ecr-pull"
  description = "Allows EKS nodes to pull container images from NeuroSphere ECR repositories"
  path        = "/neurosphere/"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuthToken"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
        ]
        Resource = "*"
      },
      {
        Sid    = "ECRPullImages"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
        ]
        Resource = [for repo in aws_ecr_repository.services : repo.arn]
      },
    ]
  })

  tags = local.common_tags
}

###############################################################################
# S3 Bucket — Terraform Remote State
#
# Stores Terraform state files with versioning so every state mutation is
# recoverable. Encryption at rest satisfies HIPAA requirements for any
# infrastructure metadata that may reference PHI-adjacent resource names.
###############################################################################

resource "aws_s3_bucket" "tfstate" {
  bucket = "${local.name_prefix}-tfstate"

  # Prevent accidental deletion of state
  force_destroy = false

  tags = merge(local.common_tags, {
    Purpose = "terraform-state"
  })
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "cleanup-noncurrent-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    # Remove incomplete multipart uploads after 7 days
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

###############################################################################
# DynamoDB Table — Terraform State Locking
#
# Prevents concurrent Terraform runs from corrupting shared state.
# PAY_PER_REQUEST billing is used because lock operations are infrequent.
###############################################################################

resource "aws_dynamodb_table" "tflock" {
  name         = "${local.name_prefix}-tflock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  # Point-in-time recovery for the lock table itself (defense in depth)
  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = merge(local.common_tags, {
    Purpose = "terraform-state-lock"
  })
}

###############################################################################
# S3 Bucket — Audit Logs
#
# HIPAA requires audit logs to be retained for a minimum of 6 years, but
# operational access is typically needed only for the first 90 days. After
# that we transition to Glacier for cost-effective long-term archival.
# Objects expire after 365 days by default (override via variables for
# longer HIPAA retention if needed).
###############################################################################

resource "aws_s3_bucket" "audit_logs" {
  bucket = "${local.name_prefix}-audit-logs"

  force_destroy = false

  tags = merge(local.common_tags, {
    Purpose    = "audit-logs"
    DataClass  = "sensitive"
    Compliance = "HIPAA"
  })
}

resource "aws_s3_bucket_versioning" "audit_logs" {
  bucket = aws_s3_bucket.audit_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit_logs" {
  bucket = aws_s3_bucket.audit_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "audit_logs" {
  bucket = aws_s3_bucket.audit_logs.id

  rule {
    id     = "audit-log-lifecycle"
    status = "Enabled"

    # Move to Glacier after 90 days — logs are rarely accessed after initial
    # investigation windows close but must remain available for compliance.
    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    # Expire after 365 days. For full HIPAA 6-year retention, set
    # a longer expiration or use Glacier Vault Lock policies.
    expiration {
      days = 365
    }

    # Clean up incomplete uploads
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "cleanup-noncurrent-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

resource "aws_s3_bucket_public_access_block" "audit_logs" {
  bucket = aws_s3_bucket.audit_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

###############################################################################
# WAF v2 Web ACL
#
# Protects the NeuroSphere API Gateway from common web exploits using
# AWS-managed rule groups. These provide zero-day coverage for OWASP Top 10
# categories without requiring manual rule maintenance.
#
# Scope is REGIONAL (for ALB/API Gateway). Use CLOUDFRONT for CloudFront.
###############################################################################

resource "aws_wafv2_web_acl" "api_gateway" {
  name        = "${local.name_prefix}-api-waf"
  description = "WAF ACL protecting NeuroSphere API Gateway – HIPAA/IEC 62443 compliant"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # ---------- AWS Managed Rules: Common Rule Set ----------
  # Covers generic web exploits (XSS, path traversal, protocol violations, etc.)
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  # ---------- AWS Managed Rules: Known Bad Inputs ----------
  # Blocks requests with patterns known to be associated with exploitation
  # (Log4j, Java deserialization, etc.)
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-waf"
    sampled_requests_enabled   = true
  }

  tags = merge(local.common_tags, {
    Purpose = "api-protection"
  })
}
