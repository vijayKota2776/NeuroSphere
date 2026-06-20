# ===========================================================================
# NeuroSphere — Production Environment Configuration
# High availability, maximum security, full compliance
# ===========================================================================

module "neurosphere" {
  source = "../../"

  environment          = "prod"
  aws_region           = var.aws_region
  project_name         = "neurosphere"
  enable_ha_nat        = true  # Multi-AZ NAT for HA
  kubernetes_version   = "1.29"
  node_instance_types  = ["t3.xlarge", "t3.2xlarge"]
  node_min_size        = 3
  node_max_size        = 10
  node_desired_size    = 5
  alert_email          = var.alert_email
  enable_public_endpoint = false  # Private-only API in production

  tags = {
    Environment = "prod"
    CostCenter  = "operations"
    Compliance  = "HIPAA-BAA"
    DataClass   = "PHI"
  }
}

variable "aws_region" {
  description = "AWS region for production deployment"
  type        = string
  default     = "us-east-1"
}

variable "alert_email" {
  description = "Email address for production alert notifications"
  type        = string
  default     = "prod-alerts@neurosphere.io"
}

# Outputs
output "vpc_id" {
  value = module.neurosphere.vpc_id
}

output "eks_cluster_endpoint" {
  value     = module.neurosphere.eks_cluster_endpoint
  sensitive = true  # Hide prod endpoint from logs
}

output "eks_cluster_name" {
  value = module.neurosphere.eks_cluster_name
}
