# ===========================================================================
# NeuroSphere — Staging State Backend
# ===========================================================================
terraform {
  backend "s3" {
    bucket         = "neurosphere-staging-tfstate"
    key            = "infrastructure/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "neurosphere-staging-tflock"
  }
}
