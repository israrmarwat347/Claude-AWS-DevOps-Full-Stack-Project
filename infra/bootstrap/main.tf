terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  # First apply uses local state. Then migrate using docs/SETUP.md.
}
provider "aws" {
  region = var.aws_region
  default_tags { tags = { Project = var.project, ManagedBy = "Terraform" } }
}
variable "aws_region" {
  type    = string
  default = "eu-west-1"
}
variable "project" {
  type    = string
  default = "claude-platform"
}
variable "github_repository" {
  type        = string
  description = "# TODO: OWNER/REPOSITORY, case-sensitive, no URL prefix."
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "Use OWNER/REPOSITORY."
  }
}
variable "route53_zone_id" { type = string }
variable "existing_oidc_provider_arn" {
  type        = string
  default     = ""
  description = "# TODO: Reuse an existing GitHub OIDC provider if this account already has one."
}
data "aws_caller_identity" "current" {}
locals {
  account = data.aws_caller_identity.current.account_id
  region  = var.aws_region
  envs    = toset(["dev", "staging", "prod"])
  oidc    = var.existing_oidc_provider_arn != "" ? var.existing_oidc_provider_arn : aws_iam_openid_connect_provider.github[0].arn
}
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.existing_oidc_provider_arn == "" ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}
resource "aws_s3_bucket" "state" {
  bucket        = "${var.project}-${local.account}-tfstate"
  force_destroy = false
  lifecycle { prevent_destroy = true }
}
resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_kms_key" "state" {
  description             = "Terraform state encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  lifecycle { prevent_destroy = true }
}
resource "aws_kms_alias" "state" {
  name          = "alias/${var.project}-tfstate"
  target_key_id = aws_kms_key.state.key_id
}
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Deny", Principal = "*", Action = "s3:*",
    Resource = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"],
  Condition = { Bool = { "aws:SecureTransport" = "false" } } }] })
}
resource "aws_ecr_repository" "api" {
  for_each             = local.envs
  name                 = "${var.project}-${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
}
resource "aws_ecr_lifecycle_policy" "api" {
  for_each   = local.envs
  repository = aws_ecr_repository.api[each.key].name
  policy = jsonencode({ rules = [{ rulePriority = 1, description = "Retain ten untagged layers",
    selection = { tagStatus = "untagged", countType = "imageCountMoreThan", countNumber = 10 },
  action = { type = "expire" } }] })
}
resource "aws_iam_policy" "runtime_boundary" {
  name = "${var.project}-runtime-boundary"
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
    { Effect = "Allow", Action = ["logs:DescribeLogGroups"], Resource = "*" },
    { Effect = "Allow", Action = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"],
    Resource = "arn:aws:ecr:${local.region}:${local.account}:repository/${var.project}-*" },
    { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"],
    Resource = ["arn:aws:logs:${local.region}:${local.account}:log-group:/ecs/${var.project}-*:*", "arn:aws:logs:${local.region}:${local.account}:log-group:/vpc/${var.project}-*:*"] },
    { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"],
    Resource = "arn:aws:dynamodb:${local.region}:${local.account}:table/${var.project}-*-chat" },
    { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"],
    Resource = "arn:aws:secretsmanager:${local.region}:${local.account}:secret:${var.project}-*/anthropic-*" }
  ] })
}
resource "aws_iam_role" "deploy" {
  for_each = local.envs
  name     = "${var.project}-deploy-${each.key}"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow",
    Principal = { Federated = local.oidc }, Action = "sts:AssumeRoleWithWebIdentity",
    Condition = { StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com",
  "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:environment:${each.key}" } } }] })
}
resource "aws_iam_role" "plan" {
  for_each = local.envs
  name     = "${var.project}-plan-${each.key}"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow",
    Principal = { Federated = local.oidc }, Action = "sts:AssumeRoleWithWebIdentity",
    Condition = { StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com",
  "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:pull_request" } } }] })
}
resource "aws_iam_role" "build" {
  name = "${var.project}-build"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow",
    Principal = { Federated = local.oidc }, Action = "sts:AssumeRoleWithWebIdentity",
    Condition = { StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub" = ["repo:${var.github_repository}:ref:refs/heads/dev",
  "repo:${var.github_repository}:ref:refs/heads/main"] } } }] })
}
resource "aws_iam_role_policy" "build" {
  role = aws_iam_role.build.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
    { Effect = "Allow", Action = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage", "ecr:DescribeImages",
      "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage"],
    Resource = [for r in aws_ecr_repository.api : r.arn] }
  ] })
}
output "state_bucket" { value = aws_s3_bucket.state.id }
output "state_kms_key_arn" { value = aws_kms_key.state.arn }
output "runtime_boundary_arn" { value = aws_iam_policy.runtime_boundary.arn }
output "build_role_arn" { value = aws_iam_role.build.arn }
output "deploy_role_arns" { value = { for k, r in aws_iam_role.deploy : k => r.arn } }
output "plan_role_arns" { value = { for k, r in aws_iam_role.plan : k => r.arn } }
output "ecr_repositories" { value = { for k, r in aws_ecr_repository.api : k => r.repository_url } }

# No secret version: populate with scripts/set-secret.py after this bootstrap apply.
resource "aws_secretsmanager_secret" "anthropic" {
  for_each                = local.envs
  name                    = "${var.project}-${each.key}/anthropic"
  recovery_window_in_days = 30
}
output "anthropic_secret_arns" {
  value = { for k, secret in aws_secretsmanager_secret.anthropic : k => secret.arn }
}

resource "aws_sns_topic" "notifications" {
  for_each          = local.envs
  name              = "${var.project}-${each.key}-notifications"
  kms_master_key_id = aws_kms_key.notifications.arn
}
output "notification_topic_arns" { value = { for k, t in aws_sns_topic.notifications : k => t.arn } }

resource "aws_kms_key" "notifications" {
  description             = "Encrypt project SNS notifications"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Sid = "AccountAdministration", Effect = "Allow", Principal = { AWS = "arn:aws:iam::${local.account}:root" }, Action = "kms:*", Resource = "*" },
    { Sid    = "CloudWatchAlarms", Effect = "Allow", Principal = { Service = "cloudwatch.amazonaws.com" },
      Action = ["kms:Decrypt", "kms:GenerateDataKey*"], Resource = "*",
    Condition = { StringEquals = { "aws:SourceAccount" = local.account } } }
  ] })
}
