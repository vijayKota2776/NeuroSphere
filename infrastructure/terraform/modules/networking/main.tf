###############################################################################
# NeuroSphere Medical Robotics — Networking Module
# ---------------------------------------------------------------------------
# Creates a production-grade VPC topology designed for healthcare workloads
# running on Amazon EKS.
#
# Design decisions:
#   • Three subnet tiers (public / private / database) to enforce network
#     isolation required by HIPAA and IEC 62443.
#   • Database subnets are fully isolated — no route to the internet — so
#     PHI-at-rest is never directly reachable from outside the VPC.
#   • VPC Flow Logs ship to CloudWatch for the audit trail mandated by the
#     HIPAA Security Rule (§164.312(b)).
#   • EKS-specific tags on public and private subnets enable automatic
#     load-balancer discovery by the AWS Load Balancer Controller.
#   • A single NAT Gateway keeps costs low in non-production environments;
#     enabling `enable_ha_nat` provisions one NAT per AZ for fault tolerance.
###############################################################################

# ---------------------------------------------------------------------------
# Local values — computed naming / tagging conventions
# ---------------------------------------------------------------------------
locals {
  name_prefix = "neurosphere-${var.environment}"

  # Merge caller-supplied tags with mandatory compliance tags
  common_tags = merge(var.tags, {
    Project     = "neurosphere"
    Environment = var.environment
    Compliance  = "HIPAA"
    ManagedBy   = "terraform"
  })

  # How many AZs / subnets to create
  az_count = length(var.availability_zones)

  # CIDR blocks for each subnet tier
  public_cidrs   = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_cidrs  = ["10.0.10.0/24", "10.0.20.0/24", "10.0.30.0/24"]
  database_cidrs = ["10.0.100.0/24", "10.0.101.0/24", "10.0.102.0/24"]

  # Number of NAT Gateways: one per AZ in HA mode, otherwise a single one
  nat_count = var.enable_ha_nat ? local.az_count : 1
}

###############################################################################
# VPC
###############################################################################
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc"
  })
}

###############################################################################
# Internet Gateway — provides internet access for public subnets
###############################################################################
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-igw"
  })
}

###############################################################################
# Public Subnets
# ---------------------------------------------------------------------------
# Tagged with kubernetes.io/role/elb = 1 so the AWS LB Controller can
# automatically provision internet-facing ALBs / NLBs in these subnets.
###############################################################################
resource "aws_subnet" "public" {
  count = local.az_count

  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name                                = "${local.name_prefix}-public-${var.availability_zones[count.index]}"
    Tier                                = "public"
    "kubernetes.io/role/elb"            = "1"
    "kubernetes.io/cluster/neurosphere-${var.environment}" = "shared"
  })
}

###############################################################################
# Private Subnets (application / EKS worker nodes)
# ---------------------------------------------------------------------------
# Tagged with kubernetes.io/role/internal-elb = 1 for internal LBs.
# Outbound internet access is provided via the NAT Gateway.
###############################################################################
resource "aws_subnet" "private" {
  count = local.az_count

  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(local.common_tags, {
    Name                                = "${local.name_prefix}-private-${var.availability_zones[count.index]}"
    Tier                                = "private"
    "kubernetes.io/role/internal-elb"   = "1"
    "kubernetes.io/cluster/neurosphere-${var.environment}" = "shared"
  })
}

###############################################################################
# Database Subnets (isolated — no internet route)
# ---------------------------------------------------------------------------
# These subnets host RDS, ElastiCache, and other data stores that contain
# PHI.  They have NO route to the internet, satisfying HIPAA network
# isolation requirements.
###############################################################################
resource "aws_subnet" "database" {
  count = local.az_count

  vpc_id            = aws_vpc.main.id
  cidr_block        = local.database_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(local.common_tags, {
    Name       = "${local.name_prefix}-database-${var.availability_zones[count.index]}"
    Tier       = "database"
    DataClass  = "PHI"
  })
}

###############################################################################
# Elastic IPs for NAT Gateway(s)
###############################################################################
resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-nat-eip-${count.index + 1}"
  })

  # EIPs should be created after the IGW exists so that the NAT Gateway
  # (which depends on the EIP) can route through the IGW.
  depends_on = [aws_internet_gateway.main]
}

###############################################################################
# NAT Gateway(s)
# ---------------------------------------------------------------------------
# Single NAT by default (dev/staging).  Set enable_ha_nat = true for
# production to get one NAT per AZ, eliminating a single point of failure.
###############################################################################
resource "aws_nat_gateway" "main" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-nat-${count.index + 1}"
  })

  depends_on = [aws_internet_gateway.main]
}

###############################################################################
# Route Tables
###############################################################################

# --- Public Route Table ---------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-rt"
    Tier = "public"
  })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count = local.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- Private Route Table(s) -----------------------------------------------
# In HA mode each AZ gets its own route table pointing to its own NAT GW.
# In single-NAT mode all private subnets share one route table.
resource "aws_route_table" "private" {
  count  = local.nat_count
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-rt-${count.index + 1}"
    Tier = "private"
  })
}

resource "aws_route" "private_nat" {
  count = local.nat_count

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[count.index].id
}

resource "aws_route_table_association" "private" {
  count = local.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[var.enable_ha_nat ? count.index : 0].id
}

# --- Database Route Table (isolated — NO default route) --------------------
resource "aws_route_table" "database" {
  vpc_id = aws_vpc.main.id

  # Intentionally NO default route.  Database subnets must remain isolated
  # to protect PHI in compliance with HIPAA network segmentation rules.

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-database-rt"
    Tier = "database"
  })
}

resource "aws_route_table_association" "database" {
  count = local.az_count

  subnet_id      = aws_subnet.database[count.index].id
  route_table_id = aws_route_table.database.id
}

###############################################################################
# VPC Flow Logs → CloudWatch  (HIPAA audit trail)
# ---------------------------------------------------------------------------
# The HIPAA Security Rule (§164.312(b)) requires audit controls that record
# and examine activity in systems containing ePHI.  VPC Flow Logs capture
# all accepted and rejected traffic in the VPC.
###############################################################################

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  name              = "/aws/vpc/flow-logs/${local.name_prefix}"
  retention_in_days = 365 # 1-year retention for HIPAA audit requirements

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc-flow-logs"
  })
}

# IAM role that allows the VPC Flow Log service to write to CloudWatch
resource "aws_iam_role" "vpc_flow_logs" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  name = "${local.name_prefix}-vpc-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "vpc-flow-logs.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc-flow-logs-role"
  })
}

resource "aws_iam_role_policy" "vpc_flow_logs" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  name = "${local.name_prefix}-vpc-flow-logs-policy"
  role = aws_iam_role.vpc_flow_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_flow_log" "main" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  vpc_id               = aws_vpc.main.id
  traffic_type         = "ALL" # Capture both ACCEPT and REJECT for full audit
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.vpc_flow_logs[0].arn
  iam_role_arn         = aws_iam_role.vpc_flow_logs[0].arn

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc-flow-log"
  })
}

###############################################################################
# DB Subnet Group — used by future RDS / Aurora deployments
# ---------------------------------------------------------------------------
# Placing the subnet group in the networking module ensures that all
# database services automatically land in the isolated database subnets.
###############################################################################
resource "aws_db_subnet_group" "main" {
  name       = "${local.name_prefix}-db-subnet-group"
  subnet_ids = aws_subnet.database[*].id

  description = "Database subnet group for NeuroSphere ${var.environment} environment (isolated, no internet)"

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-db-subnet-group"
  })
}
