# NeuroSphere Medical Robotics - Root Variables
# All configurable parameters for the infrastructure stack.
# Sensitive values should be provided via environment variables or tfvars files,
# never committed to version control.

# -----------------------------------------------------------------------------
# General / Project
# -----------------------------------------------------------------------------

variable "environment" {
  description = "Deployment environment (dev, staging, prod). Controls resource sizing, HA configuration, and compliance strictness."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "aws_region" {
  description = "AWS region for all resources. Choose a region with EKS and all required services available."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^(us|eu|ap|sa|ca|me|af)-(north|south|east|west|central|southeast|northeast)-[0-9]+$", var.aws_region))
    error_message = "Must be a valid AWS region identifier (e.g., us-east-1, eu-west-2)."
  }
}

variable "project_name" {
  description = "Project identifier used in resource naming and tagging. Lowercase alphanumeric and hyphens only."
  type        = string
  default     = "neurosphere"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project_name))
    error_message = "Project name must be 3-21 chars, start with a letter, and contain only lowercase alphanumeric characters and hyphens."
  }
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Must be large enough for public, private, and database subnets across all AZs."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "VPC CIDR must be a valid IPv4 CIDR block."
  }
}

variable "enable_ha_nat" {
  description = "Deploy one NAT Gateway per AZ for high availability. Required for prod, optional for lower environments to reduce cost."
  type        = bool
  default     = false
}

variable "enable_public_endpoint" {
  description = "Enable public access to the EKS API server endpoint. Should be false in prod for HIPAA compliance; useful in dev for local kubectl access."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Kubernetes / EKS
# -----------------------------------------------------------------------------

variable "kubernetes_version" {
  description = "EKS Kubernetes version. Must be a supported version. Upgrades should be tested in staging first."
  type        = string
  default     = "1.29"

  validation {
    condition     = can(regex("^1\\.(2[7-9]|3[0-9])$", var.kubernetes_version))
    error_message = "Kubernetes version must be 1.27 or higher."
  }
}

variable "node_instance_types" {
  description = "EC2 instance types for the EKS managed node group. Multiple types enable better Spot availability. Use compute-optimized for robotics workloads."
  type        = list(string)
  default     = ["t3.medium"]

  validation {
    condition     = length(var.node_instance_types) > 0
    error_message = "At least one instance type must be specified."
  }
}

variable "node_min_size" {
  description = "Minimum number of nodes in the EKS managed node group. Must be >= 1 for cluster stability."
  type        = number
  default     = 1

  validation {
    condition     = var.node_min_size >= 1
    error_message = "Minimum node count must be at least 1."
  }
}

variable "node_max_size" {
  description = "Maximum number of nodes in the EKS managed node group. Sets the ceiling for cluster autoscaler."
  type        = number
  default     = 5

  validation {
    condition     = var.node_max_size >= 1
    error_message = "Maximum node count must be at least 1."
  }
}

variable "node_desired_size" {
  description = "Desired number of nodes in the EKS managed node group at steady state."
  type        = number
  default     = 2

  validation {
    condition     = var.node_desired_size >= 1
    error_message = "Desired node count must be at least 1."
  }
}

# -----------------------------------------------------------------------------
# Monitoring / Alerts
# -----------------------------------------------------------------------------

variable "alert_email" {
  description = "Email address for infrastructure and compliance alert notifications via SNS."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", var.alert_email))
    error_message = "Must be a valid email address."
  }
}

variable "enable_monitoring" {
  description = "Deploy the monitoring stack (Prometheus, Grafana, alert rules). Disable in dev to save costs."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days. HIPAA requires minimum 6 years (2190 days) for audit logs in production."
  type        = number
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "Log retention must be a CloudWatch-supported value."
  }
}

# -----------------------------------------------------------------------------
# Tags
# -----------------------------------------------------------------------------

variable "tags" {
  description = "Additional tags to apply to all resources. Merged with default project tags. Use for team ownership, cost center, etc."
  type        = map(string)
  default     = {}
}
