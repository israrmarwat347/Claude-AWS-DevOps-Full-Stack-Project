variable "project" {
  type    = string
  default = "claude-platform"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,19}$", var.project))
    error_message = "Use 3-20 lowercase letters, digits or hyphens."
  }
}
variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Use dev, staging or prod."
  }
}
variable "aws_region" {
  type    = string
  default = "eu-west-1"
}
variable "domain_name" {
  description = "# TODO: Existing domain delegated to the Route 53 public hosted zone."
  type        = string
}
variable "route53_zone_id" {
  description = "# TODO: Public hosted zone ID."
  type        = string
}
variable "image_uri" {
  description = "Immutable ECR image digest, supplied by the deployment workflow."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/[a-z0-9/-]+@sha256:[a-f0-9]{64}$", var.image_uri))
    error_message = "image_uri must be a private ECR image pinned by sha256 digest."
  }
}
variable "release_sha" {
  description = "Git commit that produced the image; shown by health endpoint."
  type        = string
}
variable "vpc_cidr" { type = string }
variable "high_availability_nat" {
  type    = bool
  default = false
}
variable "task_count" {
  type    = number
  default = 1
}
variable "max_tasks" {
  type    = number
  default = 3
}
variable "task_cpu" {
  type    = number
  default = 256
}
variable "task_memory" {
  type    = number
  default = 512
}
variable "retention_days" {
  type    = number
  default = 30
}
variable "claude_model" {
  type    = string
  default = "claude-haiku-4-5-20251001"
}
variable "runtime_boundary_arn" {
  description = "Boundary ARN produced by infra/bootstrap."
  type        = string
}
variable "enable_waf" {
  type    = bool
  default = false
}
