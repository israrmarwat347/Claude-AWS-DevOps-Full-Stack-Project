terraform {
  required_version = ">= 1.10, < 2.0"
  backend "s3" {}
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.7" }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = { Project = var.project, Environment = var.environment, ManagedBy = "Terraform" }
  }
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" { state = "available" }
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

locals {
  name        = "${var.project}-${var.environment}"
  account     = data.aws_caller_identity.current.account_id
  origin_host = "${var.environment}-api.${var.domain_name}"
  azs         = slice(data.aws_availability_zones.available.names, 0, 2)
  nat_count   = var.high_availability_nat ? 2 : 1
}
