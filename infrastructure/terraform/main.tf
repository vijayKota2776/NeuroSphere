# NeuroSphere Medical Robotics - Root Module Orchestration
# Wires together all infrastructure modules with proper dependency ordering.
#
# Module Dependency Graph:
#   networking ─┬─► security ─► kubernetes ─► monitoring
#               └──────────────►
#
# Design Decisions:
# - Each module is self-contained with its own variables/outputs
# - Cross-module references use explicit output→input wiring
# - Healthcare compliance (HIPAA, IEC 62443) is enforced at every layer

locals {
  # Standard naming convention: {project}-{environment}-{resource}
  name_prefix = "${var.project_name}-${var.environment}"

  # Merge user-provided tags with computed tags
  common_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Compliance  = "HIPAA-IEC62443"
    },
    var.tags,
  )

  # AWS account info for ARN construction
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
}

# -----------------------------------------------------------------------------
# Networking Module
# Creates VPC, subnets (public/private/database), NAT Gateways, route tables,
# VPC Flow Logs, and network ACLs. This is the foundation layer.
# HIPAA: VPC Flow Logs enabled for network audit trail.
# IEC 62443: Network segmentation via separate subnet tiers.
# -----------------------------------------------------------------------------
module "networking" {
  source = "./modules/networking"

  environment    = var.environment
  project_name   = var.project_name
  vpc_cidr       = var.vpc_cidr
  enable_ha_nat  = var.enable_ha_nat
  name_prefix    = local.name_prefix
  tags           = local.common_tags
}

# -----------------------------------------------------------------------------
# Security Module
# Creates IAM roles/policies, KMS keys, security groups, and compliance
# configurations. Depends on networking for VPC-scoped security groups.
# HIPAA: Encryption keys for data at rest, least-privilege IAM.
# IEC 62443: Role-based access control, audit logging.
# -----------------------------------------------------------------------------
module "security" {
  source = "./modules/security"

  environment  = var.environment
  project_name = var.project_name
  name_prefix  = local.name_prefix
  vpc_id       = module.networking.vpc_id
  vpc_cidr     = var.vpc_cidr
  tags         = local.common_tags
}

# -----------------------------------------------------------------------------
# Kubernetes (EKS) Module
# Creates the EKS cluster, managed node groups, OIDC provider, and cluster
# add-ons. Depends on networking (subnets) and security (IAM roles, SGs).
# HIPAA: Encrypted etcd, private API endpoint, audit logging.
# IEC 62443: Network-isolated control plane, RBAC-ready.
# -----------------------------------------------------------------------------
module "kubernetes" {
  source = "./modules/kubernetes"

  environment            = var.environment
  project_name           = var.project_name
  name_prefix            = local.name_prefix
  kubernetes_version     = var.kubernetes_version
  vpc_id                 = module.networking.vpc_id
  private_subnet_ids     = module.networking.private_subnet_ids
  node_instance_types    = var.node_instance_types
  node_min_size          = var.node_min_size
  node_max_size          = var.node_max_size
  node_desired_size      = var.node_desired_size
  enable_public_endpoint = var.enable_public_endpoint
  cluster_security_group_id   = module.security.cluster_security_group_id
  node_security_group_id      = module.security.node_security_group_id
  cluster_role_arn            = module.security.cluster_role_arn
  node_role_arn               = module.security.node_role_arn
  kms_key_arn                 = module.security.kms_key_arn
  log_retention_days          = var.log_retention_days
  tags                        = local.common_tags

  depends_on = [
    module.networking,
    module.security,
  ]
}

# -----------------------------------------------------------------------------
# Monitoring Module
# Deploys Prometheus, Grafana, CloudWatch dashboards, SNS alerting, and
# custom metrics for robotics telemetry. Depends on kubernetes for the
# EKS cluster and Helm provider.
# HIPAA: Audit log aggregation, access monitoring alerts.
# IEC 62443: Real-time anomaly detection, safety system monitoring.
# -----------------------------------------------------------------------------
module "monitoring" {
  source = "./modules/monitoring"

  environment       = var.environment
  project_name      = var.project_name
  name_prefix       = local.name_prefix
  cluster_name      = module.kubernetes.cluster_name
  cluster_endpoint  = module.kubernetes.cluster_endpoint
  cluster_oidc_issuer_url = module.kubernetes.oidc_issuer_url
  alert_email       = var.alert_email
  enable_monitoring = var.enable_monitoring
  log_retention_days = var.log_retention_days
  tags              = local.common_tags

  depends_on = [
    module.kubernetes,
  ]
}

# -----------------------------------------------------------------------------
# ECR Repositories
# Container registries for NeuroSphere microservices.
# Each service gets its own repository with image scanning enabled.
# HIPAA: Image scanning for vulnerability compliance.
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "services" {
  for_each = toset([
    "motion-engine",
    "telemetry-service",
    "safety-controller",
    "auth-service",
    "api-gateway",
  ])

  name                 = "${local.name_prefix}-${each.key}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = module.security.kms_key_arn
  }

  tags = merge(local.common_tags, {
    Service = each.key
  })
}

# ECR lifecycle policy to manage image retention and control storage costs
resource "aws_ecr_lifecycle_policy" "services" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 30 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"]
          countType     = "imageCountMoreThan"
          countNumber   = 30
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Remove untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      },
    ]
  })
}
