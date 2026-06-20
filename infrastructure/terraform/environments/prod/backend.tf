# ===========================================================================
# NeuroSphere — Production State Backend
# ===========================================================================
terraform {
  backend "s3" {
    bucket         = "neurosphere-prod-tfstate"
    key            = "infrastructure/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "neurosphere-prod-tflock"
  }
}
