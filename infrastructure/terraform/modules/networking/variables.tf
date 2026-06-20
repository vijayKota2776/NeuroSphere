###############################################################################
# NeuroSphere Medical Robotics — Networking Module Variables
###############################################################################

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, production). Used in resource naming and tagging."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "environment must be one of: dev, staging, production."
  }
}

variable "aws_region" {
  description = "AWS region for networking resources. Should match the provider region."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must be a valid AWS region identifier (e.g. us-east-1)."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Must be large enough to accommodate public, private, and database subnets."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block (e.g. 10.0.0.0/16)."
  }
}

variable "availability_zones" {
  description = "List of AWS Availability Zones. Three AZs are recommended for HA in healthcare workloads."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]

  validation {
    condition     = length(var.availability_zones) >= 2 && length(var.availability_zones) <= 3
    error_message = "availability_zones must contain 2 or 3 entries for healthcare-grade high availability."
  }
}

variable "enable_ha_nat" {
  description = <<-EOT
    Deploy one NAT Gateway per AZ for high availability. Recommended for
    production environments to eliminate a single point of failure. Increases
    cost proportionally to the number of AZs.
  EOT
  type        = bool
  default     = false
}

variable "enable_vpc_flow_logs" {
  description = <<-EOT
    Enable VPC Flow Logs to CloudWatch. Required for HIPAA compliance
    (§164.312(b) audit controls). Strongly recommended to keep enabled
    in all environments.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags to merge with the default compliance tags applied to all resources."
  type        = map(string)
  default     = {}
}
