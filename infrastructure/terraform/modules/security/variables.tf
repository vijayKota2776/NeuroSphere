###############################################################################
# NeuroSphere Medical Robotics — Security Module Variables
###############################################################################

variable "environment" {
  description = "Deployment environment (dev, staging, prod). Controls naming, retention policies, and compliance strictness."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "aws_region" {
  description = "AWS region for resource deployment. Should match the region used by EKS and VPC modules."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]+$", var.aws_region))
    error_message = "aws_region must be a valid AWS region identifier (e.g. us-east-1, eu-west-2)."
  }
}

variable "service_names" {
  description = "List of microservice names that need ECR repositories. Each name is used as a suffix in the repository name."
  type        = list(string)
  default = [
    "robot-command-service",
    "diagnostic-engine-service",
    "patient-monitor-service",
    "telemetry-ingest-service",
  ]

  validation {
    condition     = length(var.service_names) > 0
    error_message = "At least one service name must be provided."
  }

  validation {
    condition     = alltrue([for s in var.service_names : can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", s))])
    error_message = "Service names must be lowercase alphanumeric with hyphens, and cannot start or end with a hyphen."
  }
}

variable "tags" {
  description = "Additional tags to apply to all resources. Merged with module-level defaults (Project, Environment, Compliance, ManagedBy)."
  type        = map(string)
  default     = {}
}
