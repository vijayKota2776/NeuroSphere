# NeuroSphere Medical Robotics - Terraform Backend Configuration
#
# IMPORTANT: Remote backend setup requires a two-phase approach:
#
# Phase 1 - Bootstrap (first-time setup):
#   1. Leave this file commented out
#   2. Run `terraform init` to use local state
#   3. Create the S3 bucket and DynamoDB table using the bootstrap script:
#      ../scripts/bootstrap-backend.sh
#   4. Uncomment the backend block below
#   5. Run `terraform init -migrate-state` to move state to S3
#
# Phase 2 - Normal operation:
#   Use environment-specific backend configs in /environments/<env>/backend.tf
#   Each environment has its own state file to prevent accidental cross-env changes.
#
# State File Security (HIPAA Compliance):
#   - S3 bucket has versioning enabled for state recovery
#   - Server-side encryption (AES-256) protects state at rest
#   - Bucket policy restricts access to authorized IAM roles only
#   - DynamoDB table provides state locking to prevent concurrent modifications
#   - Access logging enabled on the S3 bucket for audit trail

# terraform {
#   backend "s3" {
#     bucket         = "neurosphere-terraform-state"
#     key            = "infrastructure/terraform.tfstate"
#     region         = "us-east-1"
#     encrypt        = true
#     dynamodb_table = "neurosphere-terraform-locks"
#
#     # Uncomment to assume a specific role for state access
#     # role_arn     = "arn:aws:iam::ACCOUNT_ID:role/neurosphere-terraform-state"
#   }
# }
