###############################################################################
# NeuroSphere Medical Robotics — Monitoring Module Outputs
###############################################################################

output "log_group_names" {
  description = "Map of service key to CloudWatch Log Group name. Use in Fluentd/Fluent Bit configurations for EKS pod log shipping."
  value       = { for key, lg in aws_cloudwatch_log_group.services : key => lg.name }
}

output "log_group_arns" {
  description = "Map of service key to CloudWatch Log Group ARN. Useful for IAM policy construction."
  value       = { for key, lg in aws_cloudwatch_log_group.services : key => lg.arn }
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic used for alarm notifications. Subscribe additional endpoints (Lambda, HTTPS) as needed."
  value       = aws_sns_topic.alerts.arn
}

output "sns_topic_name" {
  description = "Name of the SNS alerts topic."
  value       = aws_sns_topic.alerts.name
}

output "dashboard_name" {
  description = "Name of the CloudWatch operations dashboard."
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}

output "alarm_arns" {
  description = "Map of alarm identifiers to their ARNs. Useful for creating composite alarms or external integrations."
  value = {
    eks_cpu_high             = aws_cloudwatch_metric_alarm.eks_cpu_high.arn
    eks_memory_high          = aws_cloudwatch_metric_alarm.eks_memory_high.arn
    robot_command_5xx        = aws_cloudwatch_metric_alarm.robot_command_5xx.arn
    patient_monitor_latency  = aws_cloudwatch_metric_alarm.patient_monitor_latency.arn
  }
}

output "alarm_names" {
  description = "Map of alarm identifiers to their names. Useful for reference and documentation."
  value = {
    eks_cpu_high             = aws_cloudwatch_metric_alarm.eks_cpu_high.alarm_name
    eks_memory_high          = aws_cloudwatch_metric_alarm.eks_memory_high.alarm_name
    robot_command_5xx        = aws_cloudwatch_metric_alarm.robot_command_5xx.alarm_name
    patient_monitor_latency  = aws_cloudwatch_metric_alarm.patient_monitor_latency.alarm_name
  }
}
