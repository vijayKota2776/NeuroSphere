# NeuroSphere Medical Robotics - Root Outputs
# Exposes key resource identifiers for use by CI/CD pipelines,
# environment configs, and operational tooling.

# -----------------------------------------------------------------------------
# Networking Outputs
# -----------------------------------------------------------------------------

output "vpc_id" {
  description = "ID of the NeuroSphere VPC"
  value       = module.networking.vpc_id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC"
  value       = module.networking.vpc_cidr
}

output "private_subnet_ids" {
  description = "List of private subnet IDs (EKS nodes, internal services)"
  value       = module.networking.private_subnet_ids
}

output "public_subnet_ids" {
  description = "List of public subnet IDs (load balancers, NAT gateways)"
  value       = module.networking.public_subnet_ids
}

output "database_subnet_ids" {
  description = "List of database subnet IDs (RDS, ElastiCache)"
  value       = module.networking.database_subnet_ids
}

output "nat_gateway_ips" {
  description = "Elastic IP addresses of the NAT Gateways (for allowlisting)"
  value       = module.networking.nat_gateway_ips
}

# -----------------------------------------------------------------------------
# Security Outputs
# -----------------------------------------------------------------------------

output "kms_key_arn" {
  description = "ARN of the KMS key used for data encryption (EBS, ECR, secrets)"
  value       = module.security.kms_key_arn
}

output "cluster_role_arn" {
  description = "ARN of the IAM role attached to the EKS cluster"
  value       = module.security.cluster_role_arn
}

output "node_role_arn" {
  description = "ARN of the IAM role attached to EKS worker nodes"
  value       = module.security.node_role_arn
}

# -----------------------------------------------------------------------------
# Kubernetes / EKS Outputs
# -----------------------------------------------------------------------------

output "eks_cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.kubernetes.cluster_name
}

output "eks_cluster_endpoint" {
  description = "API server endpoint for the EKS cluster"
  value       = module.kubernetes.cluster_endpoint
}

output "eks_cluster_version" {
  description = "Kubernetes version running on the EKS cluster"
  value       = module.kubernetes.cluster_version
}

output "eks_oidc_issuer_url" {
  description = "OIDC issuer URL for the EKS cluster (used for IRSA)"
  value       = module.kubernetes.oidc_issuer_url
}

output "eks_cluster_certificate_authority" {
  description = "Base64-encoded CA certificate for the EKS cluster"
  value       = module.kubernetes.cluster_certificate_authority
  sensitive   = true
}

output "eks_kubeconfig_command" {
  description = "AWS CLI command to update local kubeconfig for cluster access"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.kubernetes.cluster_name}"
}

# -----------------------------------------------------------------------------
# ECR Outputs
# -----------------------------------------------------------------------------

output "ecr_repository_urls" {
  description = "Map of service name to ECR repository URL for container image pushes"
  value = {
    for name, repo in aws_ecr_repository.services :
    name => repo.repository_url
  }
}

# -----------------------------------------------------------------------------
# Monitoring Outputs
# -----------------------------------------------------------------------------

output "monitoring_namespace" {
  description = "Kubernetes namespace where the monitoring stack is deployed"
  value       = module.monitoring.monitoring_namespace
}

output "grafana_endpoint" {
  description = "Internal endpoint for the Grafana dashboard"
  value       = module.monitoring.grafana_endpoint
}

# -----------------------------------------------------------------------------
# Convenience Outputs
# -----------------------------------------------------------------------------

output "environment" {
  description = "Current deployment environment"
  value       = var.environment
}

output "region" {
  description = "AWS region where resources are deployed"
  value       = var.aws_region
}

output "account_id" {
  description = "AWS account ID"
  value       = data.aws_caller_identity.current.account_id
}
