###############################################################################
# NeuroSphere Medical Robotics — Monitoring Module
#
# Provisions observability infrastructure for the EKS-based platform:
#   - CloudWatch Log Groups per microservice (retention varies by environment)
#   - CloudWatch Metric Alarms for CPU, memory, error rate, and latency
#   - SNS Topic for alert delivery (email, PagerDuty, Slack via subscription)
#   - CloudWatch Dashboard with operational overview widgets
#
# Healthcare context: Continuous monitoring is required by IEC 62443 for
# industrial control systems (which surgical robots fall under) and by
# HIPAA for systems that process or transmit ePHI.
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# --------------------------------------------------------------------------- #
# Data Sources
# --------------------------------------------------------------------------- #

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# --------------------------------------------------------------------------- #
# Locals
# --------------------------------------------------------------------------- #

locals {
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name
  name_prefix = "neurosphere-${var.environment}"

  # Log retention: shorter in dev to save costs, longer in prod for compliance
  log_retention_days = var.log_retention_days != null ? var.log_retention_days : (
    var.environment == "prod" ? 90 : 30
  )

  # Log group definitions — each service gets a dedicated log group
  log_groups = {
    "robot-command"     = "/neurosphere/${var.environment}/robot-command"
    "diagnostic-engine" = "/neurosphere/${var.environment}/diagnostic-engine"
    "patient-monitor"   = "/neurosphere/${var.environment}/patient-monitor"
    "telemetry-ingest"  = "/neurosphere/${var.environment}/telemetry-ingest"
    "gateway"           = "/neurosphere/${var.environment}/gateway"
  }

  common_tags = merge(var.tags, {
    Project     = "NeuroSphere"
    Environment = var.environment
    Module      = "monitoring"
    Compliance  = "HIPAA"
    ManagedBy   = "terraform"
  })
}

###############################################################################
# CloudWatch Log Groups
#
# Each microservice writes structured JSON logs to its own log group.
# KMS encryption is omitted here (uses default CloudWatch encryption) but
# can be enabled via `kms_key_id` for stricter HIPAA interpretations.
###############################################################################

resource "aws_cloudwatch_log_group" "services" {
  for_each = local.log_groups

  name              = each.value
  retention_in_days = local.log_retention_days

  tags = merge(local.common_tags, {
    Service = each.key
  })
}

###############################################################################
# SNS Topic — Alert Notifications
#
# Central fan-out point for all CloudWatch alarms. Supports email, SMS,
# Lambda, HTTPS (PagerDuty/Opsgenie), and SQS subscriptions.
###############################################################################

resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"

  # Encryption at rest for any PHI-adjacent alert payloads
  kms_master_key_id = "alias/aws/sns"

  tags = merge(local.common_tags, {
    Purpose = "alarm-notifications"
  })
}

# Email subscription — requires manual confirmation via email link
resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

###############################################################################
# CloudWatch Metric Alarms
#
# These alarms cover the four critical signals for a medical robotics
# platform. Thresholds are conservative because patient safety depends
# on responsive, reliable infrastructure.
###############################################################################

# ---------- EKS Cluster CPU Utilization ----------
# Sustained high CPU can degrade real-time robot command responsiveness.
resource "aws_cloudwatch_metric_alarm" "eks_cpu_high" {
  alarm_name          = "${local.name_prefix}-eks-cpu-utilization-high"
  alarm_description   = "EKS cluster CPU utilization exceeded 80% — risk of degraded robot command latency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "node_cpu_utilization"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "missing"

  dimensions = {
    ClusterName = var.cluster_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = merge(local.common_tags, {
    AlarmType = "infrastructure"
    Severity  = "high"
  })
}

# ---------- EKS Cluster Memory Utilization ----------
# OOM kills in medical-device services could lead to interrupted procedures.
resource "aws_cloudwatch_metric_alarm" "eks_memory_high" {
  alarm_name          = "${local.name_prefix}-eks-memory-utilization-high"
  alarm_description   = "EKS cluster memory utilization exceeded 80% — OOM risk for critical services"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "node_memory_utilization"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "missing"

  dimensions = {
    ClusterName = var.cluster_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = merge(local.common_tags, {
    AlarmType = "infrastructure"
    Severity  = "high"
  })
}

# ---------- Robot Command Service 5xx Error Rate ----------
# Even a small percentage of 5xx errors in the robot command path is
# safety-critical — commands that fail silently could leave a robot in
# an unexpected state.
resource "aws_cloudwatch_metric_alarm" "robot_command_5xx" {
  alarm_name          = "${local.name_prefix}-robot-command-5xx-rate"
  alarm_description   = "Robot command service 5xx error rate exceeded 1% — potential patient safety impact"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = 1

  metric_query {
    id          = "error_rate"
    expression  = "(errors / total) * 100"
    label       = "5xx Error Rate (%)"
    return_data = true
  }

  metric_query {
    id = "errors"

    metric {
      metric_name = "5xxError"
      namespace   = "NeuroSphere/Services"
      period      = 300
      stat        = "Sum"

      dimensions = {
        ServiceName = "robot-command-service"
        Environment = var.environment
      }
    }
  }

  metric_query {
    id = "total"

    metric {
      metric_name = "RequestCount"
      namespace   = "NeuroSphere/Services"
      period      = 300
      stat        = "Sum"

      dimensions = {
        ServiceName = "robot-command-service"
        Environment = var.environment
      }
    }
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = merge(local.common_tags, {
    AlarmType = "application"
    Severity  = "critical"
    Service   = "robot-command-service"
  })
}

# ---------- Patient Monitor Service Latency ----------
# Latency > 2s in patient monitoring could delay detection of adverse events
# during robotic surgical procedures.
resource "aws_cloudwatch_metric_alarm" "patient_monitor_latency" {
  alarm_name          = "${local.name_prefix}-patient-monitor-high-latency"
  alarm_description   = "Patient monitor service p99 latency exceeded 2000ms — delayed vital sign reporting"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "Latency"
  namespace           = "NeuroSphere/Services"
  period              = 300
  extended_statistic  = "p99"
  threshold           = 2000
  treat_missing_data  = "missing"

  dimensions = {
    ServiceName = "patient-monitor-service"
    Environment = var.environment
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = merge(local.common_tags, {
    AlarmType = "application"
    Severity  = "critical"
    Service   = "patient-monitor-service"
  })
}

###############################################################################
# CloudWatch Dashboard
#
# Provides a single-pane-of-glass operational view. Widget layout is designed
# for NOC / on-call engineers monitoring the NeuroSphere platform.
###############################################################################

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name_prefix}-operations"

  dashboard_body = jsonencode({
    widgets = [
      # ---- Row 1: EKS Cluster Health ----
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "EKS Cluster — CPU Utilization"
          region = local.region
          metrics = [
            ["ContainerInsights", "node_cpu_utilization", "ClusterName", var.cluster_name, {
              stat   = "Average"
              period = 300
              label  = "CPU Avg %"
              color  = "#FF9900"
            }],
          ]
          yAxis = {
            left = {
              min   = 0
              max   = 100
              label = "Percent"
            }
          }
          annotations = {
            horizontal = [
              {
                label = "Alarm Threshold"
                value = 80
                color = "#d62728"
              }
            ]
          }
          view = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "EKS Cluster — Memory Utilization"
          region = local.region
          metrics = [
            ["ContainerInsights", "node_memory_utilization", "ClusterName", var.cluster_name, {
              stat   = "Average"
              period = 300
              label  = "Memory Avg %"
              color  = "#1f77b4"
            }],
          ]
          yAxis = {
            left = {
              min   = 0
              max   = 100
              label = "Percent"
            }
          }
          annotations = {
            horizontal = [
              {
                label = "Alarm Threshold"
                value = 80
                color = "#d62728"
              }
            ]
          }
          view = "timeSeries"
        }
      },

      # ---- Row 2: Service Request Counts ----
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 24
        height = 6
        properties = {
          title  = "Service Request Counts (5-min intervals)"
          region = local.region
          metrics = [
            ["NeuroSphere/Services", "RequestCount", "ServiceName", "robot-command-service", "Environment", var.environment, {
              stat   = "Sum"
              period = 300
              label  = "Robot Command"
            }],
            ["NeuroSphere/Services", "RequestCount", "ServiceName", "diagnostic-engine-service", "Environment", var.environment, {
              stat   = "Sum"
              period = 300
              label  = "Diagnostic Engine"
            }],
            ["NeuroSphere/Services", "RequestCount", "ServiceName", "patient-monitor-service", "Environment", var.environment, {
              stat   = "Sum"
              period = 300
              label  = "Patient Monitor"
            }],
            ["NeuroSphere/Services", "RequestCount", "ServiceName", "telemetry-ingest-service", "Environment", var.environment, {
              stat   = "Sum"
              period = 300
              label  = "Telemetry Ingest"
            }],
          ]
          view = "timeSeries"
        }
      },

      # ---- Row 3: Error Rates ----
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "5xx Error Counts by Service"
          region = local.region
          metrics = [
            ["NeuroSphere/Services", "5xxError", "ServiceName", "robot-command-service", "Environment", var.environment, {
              stat   = "Sum"
              period = 300
              label  = "Robot Command 5xx"
              color  = "#d62728"
            }],
            ["NeuroSphere/Services", "5xxError", "ServiceName", "diagnostic-engine-service", "Environment", var.environment, {
              stat   = "Sum"
              period = 300
              label  = "Diagnostic Engine 5xx"
              color  = "#ff7f0e"
            }],
            ["NeuroSphere/Services", "5xxError", "ServiceName", "patient-monitor-service", "Environment", var.environment, {
              stat   = "Sum"
              period = 300
              label  = "Patient Monitor 5xx"
              color  = "#9467bd"
            }],
            ["NeuroSphere/Services", "5xxError", "ServiceName", "telemetry-ingest-service", "Environment", var.environment, {
              stat   = "Sum"
              period = 300
              label  = "Telemetry Ingest 5xx"
              color  = "#8c564b"
            }],
          ]
          view = "timeSeries"
        }
      },

      # ---- Row 3 (right): Latency Percentiles ----
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "Service Latency — p50 / p95 / p99"
          region = local.region
          metrics = [
            ["NeuroSphere/Services", "Latency", "ServiceName", "robot-command-service", "Environment", var.environment, {
              stat   = "p50"
              period = 300
              label  = "Robot Cmd p50"
            }],
            ["NeuroSphere/Services", "Latency", "ServiceName", "robot-command-service", "Environment", var.environment, {
              stat   = "p99"
              period = 300
              label  = "Robot Cmd p99"
            }],
            ["NeuroSphere/Services", "Latency", "ServiceName", "patient-monitor-service", "Environment", var.environment, {
              stat   = "p50"
              period = 300
              label  = "Patient Mon p50"
            }],
            ["NeuroSphere/Services", "Latency", "ServiceName", "patient-monitor-service", "Environment", var.environment, {
              stat   = "p99"
              period = 300
              label  = "Patient Mon p99"
            }],
          ]
          yAxis = {
            left = {
              label = "Milliseconds"
              min   = 0
            }
          }
          annotations = {
            horizontal = [
              {
                label = "Latency SLA (2s)"
                value = 2000
                color = "#d62728"
              }
            ]
          }
          view = "timeSeries"
        }
      },
    ]
  })
}
