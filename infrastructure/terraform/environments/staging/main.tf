# ===========================================================================
# NeuroSphere — Staging Environment Configuration
# ===========================================================================

module "neurosphere" {
  source = "../../"

  environment          = "staging"
  aws_region           = var.aws_region
  project_name         = "neurosphere"
  enable_ha_nat        = false
  kubernetes_version   = "1.29"
  node_instance_types  = ["t3.large"]
  node_min_size        = 2
  node_max_size        = 4
  node_desired_size    = 3
  alert_email          = var.alert_email
  enable_public_endpoint = true

  tags = {
    Environment = "staging"
    CostCenter  = "engineering"
  }
}

variable "aws_region" {
  description = "AWS region for staging deployment"
  type        = string
  default     = "us-east-1"
}

variable "alert_email" {
  description = "Email address for staging alert notifications"
  type        = string
  default     = "staging-alerts@neurosphere.io"
}

# Outputs
output "vpc_id" {
  value = module.neurosphere.vpc_id
}

output "eks_cluster_endpoint" {
  value = module.neurosphere.eks_cluster_endpoint
}

output "eks_cluster_name" {
  value = module.neurosphere.eks_cluster_name
}
