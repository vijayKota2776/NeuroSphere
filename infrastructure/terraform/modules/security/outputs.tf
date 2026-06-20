###############################################################################
# NeuroSphere Medical Robotics — Security Module Outputs
###############################################################################

output "ecr_repository_urls" {
  description = "Map of service name to ECR repository URL. Use these in CI/CD pipelines and EKS pod specs."
  value       = { for name, repo in aws_ecr_repository.services : name => repo.repository_url }
}

output "ecr_repository_arns" {
  description = "Map of service name to ECR repository ARN. Useful for IAM policy construction in other modules."
  value       = { for name, repo in aws_ecr_repository.services : name => repo.arn }
}

output "ecr_pull_policy_arn" {
  description = "ARN of the IAM policy that grants ECR pull access. Attach to EKS node roles or IRSA roles."
  value       = aws_iam_policy.ecr_pull.arn
}

output "tfstate_bucket_name" {
  description = "Name of the S3 bucket used for Terraform remote state storage."
  value       = aws_s3_bucket.tfstate.id
}

output "tfstate_bucket_arn" {
  description = "ARN of the Terraform state S3 bucket."
  value       = aws_s3_bucket.tfstate.arn
}

output "tflock_table_name" {
  description = "Name of the DynamoDB table used for Terraform state locking."
  value       = aws_dynamodb_table.tflock.name
}

output "tflock_table_arn" {
  description = "ARN of the DynamoDB state lock table."
  value       = aws_dynamodb_table.tflock.arn
}

output "audit_logs_bucket_name" {
  description = "Name of the S3 bucket for audit log storage (HIPAA-compliant lifecycle)."
  value       = aws_s3_bucket.audit_logs.id
}

output "audit_logs_bucket_arn" {
  description = "ARN of the audit logs S3 bucket."
  value       = aws_s3_bucket.audit_logs.arn
}

output "waf_acl_arn" {
  description = "ARN of the WAF v2 Web ACL. Associate with ALB or API Gateway resources."
  value       = aws_wafv2_web_acl.api_gateway.arn
}

output "waf_acl_id" {
  description = "ID of the WAF v2 Web ACL."
  value       = aws_wafv2_web_acl.api_gateway.id
}
