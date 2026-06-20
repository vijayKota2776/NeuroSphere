###############################################################################
# NeuroSphere Medical Robotics — Monitoring Module Variables
###############################################################################

variable "environment" {
  description = "Deployment environment (dev, staging, prod). Affects log retention, alarm sensitivity, and dashboard layout."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "cluster_name" {
  description = "Name of the EKS cluster to monitor. Used in CloudWatch metric dimensions and dashboard widgets."
  type        = string

  validation {
    condition     = length(var.cluster_name) > 0 && length(var.cluster_name) <= 100
    error_message = "cluster_name must be between 1 and 100 characters."
  }
}

variable "service_names" {
  description = "List of microservice names for monitoring configuration. Used to create per-service log groups and alarm dimensions."
  type        = list(string)
  default = [
    "robot-command-service",
    "diagnostic-engine-service",
    "patient-monitor-service",
    "telemetry-ingest-service",
  ]
}

variable "alert_email" {
  description = "Email address for SNS alarm notifications. Leave empty to skip email subscription (useful when using PagerDuty/Opsgenie instead)."
  type        = string
  default     = ""

  validation {
    condition     = var.alert_email == "" || can(regex("^[^@]+@[^@]+\\.[^@]+$", var.alert_email))
    error_message = "alert_email must be a valid email address or an empty string."
  }
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days. If null, defaults to 30 (dev) or 90 (prod). HIPAA may require longer retention for audit-relevant logs."
  type        = number
  default     = null

  validation {
    condition = var.log_retention_days == null || contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.log_retention_days
    )
    error_message = "log_retention_days must be a valid CloudWatch retention value (e.g. 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, etc.) or null."
  }
}

variable "tags" {
  description = "Additional tags to apply to all monitoring resources. Merged with module-level defaults."
  type        = map(string)
  default     = {}
}
