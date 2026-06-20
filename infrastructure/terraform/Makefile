# ===========================================================================
# NeuroSphere Terraform — Makefile
# Provides convenience targets for infrastructure management
# ===========================================================================

.PHONY: help fmt validate lint init-dev plan-dev apply-dev destroy-dev \
        init-staging plan-staging apply-staging destroy-staging \
        init-prod plan-prod apply-prod destroy-prod clean

# Default target
help: ## Show this help
	@echo "NeuroSphere Infrastructure Management"
	@echo "======================================"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Code Quality
# ---------------------------------------------------------------------------
fmt: ## Format all Terraform files
	terraform fmt -recursive .

validate: ## Validate Terraform configuration
	terraform validate

lint: ## Run fmt check (non-destructive)
	terraform fmt -check -recursive .

# ---------------------------------------------------------------------------
# Development Environment
# ---------------------------------------------------------------------------
init-dev: ## Initialize Terraform for dev
	cd environments/dev && terraform init

plan-dev: ## Plan changes for dev
	cd environments/dev && terraform plan -out=dev.tfplan

apply-dev: ## Apply changes to dev
	cd environments/dev && terraform apply dev.tfplan

destroy-dev: ## Destroy dev infrastructure (CAUTION!)
	cd environments/dev && terraform destroy

# ---------------------------------------------------------------------------
# Staging Environment
# ---------------------------------------------------------------------------
init-staging: ## Initialize Terraform for staging
	cd environments/staging && terraform init

plan-staging: ## Plan changes for staging
	cd environments/staging && terraform plan -out=staging.tfplan

apply-staging: ## Apply changes to staging
	cd environments/staging && terraform apply staging.tfplan

destroy-staging: ## Destroy staging infrastructure (CAUTION!)
	cd environments/staging && terraform destroy

# ---------------------------------------------------------------------------
# Production Environment
# ---------------------------------------------------------------------------
init-prod: ## Initialize Terraform for production
	cd environments/prod && terraform init

plan-prod: ## Plan changes for production
	cd environments/prod && terraform plan -out=prod.tfplan

apply-prod: ## Apply changes to production (REQUIRES APPROVAL!)
	@echo "⚠️  WARNING: You are about to modify PRODUCTION infrastructure"
	@echo "   This affects live medical robotics systems"
	@read -p "Type 'yes-production' to confirm: " confirm && \
		[ "$$confirm" = "yes-production" ] || (echo "Aborted." && exit 1)
	cd environments/prod && terraform apply prod.tfplan

destroy-prod: ## Destroy production infrastructure (EXTREMELY DANGEROUS!)
	@echo "🚨 DANGER: This will destroy ALL production infrastructure"
	@echo "   Active medical procedures may be affected"
	@read -p "Type 'DESTROY-PRODUCTION' to confirm: " confirm && \
		[ "$$confirm" = "DESTROY-PRODUCTION" ] || (echo "Aborted." && exit 1)
	cd environments/prod && terraform destroy

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
clean: ## Remove generated plan files and caches
	find . -name "*.tfplan" -delete
	find . -name ".terraform" -type d -exec rm -rf {} + 2>/dev/null || true
	find . -name ".terraform.lock.hcl" -delete 2>/dev/null || true
