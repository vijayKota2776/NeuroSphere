# NeuroSphere - Dev Environment Configuration
# Uses the root module with dev-appropriate sizing and cost optimizations.

terraform {
  required_version = ">= 1.5.0"
}

module "neurosphere" {
  source = "../../"

  # Environment
  environment  = "dev"
  project_name = "neurosphere"
  aws_region   = var.aws_region

  # Networking - single NAT Gateway to reduce cost
  vpc_cidr              = "10.0.0.0/16"
  enable_ha_nat         = false
  enable_public_endpoint = true # Allow local kubectl access in dev

  # EKS - minimal sizing for development workloads
  kubernetes_version = "1.29"
  node_instance_types = ["t3.medium"]
  node_min_size      = 1
  node_max_size      = 3
  node_desired_size  = 2

  # Monitoring
  alert_email       = var.alert_email
  enable_monitoring = true
  log_retention_days = 30 # Shorter retention in dev

  tags = {
    Team        = "platform-engineering"
    CostCenter  = "dev-infrastructure"
  }
}

variable "aws_region" {
  description = "AWS region for dev deployment"
  type        = string
  default     = "us-east-1"
}

variable "alert_email" {
  description = "Email for dev environment alerts"
  type        = string
}

# Pass through important outputs from the root module
output "vpc_id" {
  value = module.neurosphere.vpc_id
}

output "eks_cluster_name" {
  value = module.neurosphere.eks_cluster_name
}

output "eks_cluster_endpoint" {
  value = module.neurosphere.eks_cluster_endpoint
}

output "eks_kubeconfig_command" {
  value = module.neurosphere.eks_kubeconfig_command
}

output "ecr_repository_urls" {
  value = module.neurosphere.ecr_repository_urls
}
