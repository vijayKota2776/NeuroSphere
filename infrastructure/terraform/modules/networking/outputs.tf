###############################################################################
# NeuroSphere Medical Robotics — Networking Module Outputs
# ---------------------------------------------------------------------------
# These outputs are consumed by downstream modules (EKS, RDS, monitoring)
# to place resources in the correct subnets and reference the VPC.
###############################################################################

output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "List of public subnet IDs (internet-facing load balancers)"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "List of private subnet IDs (EKS worker nodes, application services)"
  value       = aws_subnet.private[*].id
}

output "database_subnet_ids" {
  description = "List of isolated database subnet IDs (RDS, ElastiCache — no internet route)"
  value       = aws_subnet.database[*].id
}

output "nat_gateway_ids" {
  description = "List of NAT Gateway IDs (single or one per AZ depending on enable_ha_nat)"
  value       = aws_nat_gateway.main[*].id
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway"
  value       = aws_internet_gateway.main.id
}

output "db_subnet_group_name" {
  description = "Name of the DB subnet group for RDS / Aurora deployments"
  value       = aws_db_subnet_group.main.name
}
