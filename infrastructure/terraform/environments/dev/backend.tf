# NeuroSphere - Dev State Backend
# Isolated state file for the dev environment

terraform {
  backend "s3" {
    bucket         = "neurosphere-terraform-state"
    key            = "environments/dev/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "neurosphere-terraform-locks"
  }
}
