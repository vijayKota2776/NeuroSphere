# NeuroSphere Medical Robotics - Provider Configuration
# Defines all required providers for the infrastructure stack.
# Healthcare compliance tags are applied globally via AWS default_tags.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# -----------------------------------------------------------------------------
# AWS Provider
# Default tags enforce project-wide tagging for cost allocation, compliance
# auditing, and environment segregation required by HIPAA and IEC 62443.
# -----------------------------------------------------------------------------
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Compliance  = "HIPAA-IEC62443"
    }
  }
}

# -----------------------------------------------------------------------------
# Kubernetes Provider
# Authenticates to the EKS cluster using short-lived tokens from the AWS CLI.
# This avoids storing long-lived kubeconfig credentials in state.
# -----------------------------------------------------------------------------
provider "kubernetes" {
  host                   = module.kubernetes.cluster_endpoint
  cluster_ca_certificate = base64decode(module.kubernetes.cluster_certificate_authority)
  token                  = data.aws_eks_cluster_auth.this.token
}

# -----------------------------------------------------------------------------
# Helm Provider
# Uses the same EKS authentication as the Kubernetes provider.
# Helm is used for deploying monitoring stack (Prometheus, Grafana) and
# other cluster-level services.
# -----------------------------------------------------------------------------
provider "helm" {
  kubernetes {
    host                   = module.kubernetes.cluster_endpoint
    cluster_ca_certificate = base64decode(module.kubernetes.cluster_certificate_authority)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

# Short-lived authentication token for EKS cluster access
data "aws_eks_cluster_auth" "this" {
  name = module.kubernetes.cluster_name
}

# Current AWS account and region info used across modules
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
