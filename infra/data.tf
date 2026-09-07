resource "aws_dynamodb_table" "chat" {
  name                        = "${local.name}-chat"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "pk"
  range_key                   = "sk"
  deletion_protection_enabled = var.environment == "prod"
  attribute {
    name = "pk"
    type = "S"
  }
  attribute {
    name = "sk"
    type = "S"
  }
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
  point_in_time_recovery { enabled = true }
  server_side_encryption { enabled = true }
}

# Metadata only: bootstrap owns the secret, and its value never enters Terraform state.
data "aws_secretsmanager_secret" "anthropic" {
  name = "${local.name}/anthropic"
}
resource "aws_cognito_user_pool" "users" {
  name                     = local.name
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  deletion_protection      = var.environment == "prod" ? "ACTIVE" : "INACTIVE"
  mfa_configuration        = "OPTIONAL"
  software_token_mfa_configuration { enabled = true }
  admin_create_user_config { allow_admin_create_user_only = true }
  password_policy {
    minimum_length                   = 14
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 3
  }
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}
resource "aws_cognito_user_pool_client" "web" {
  name                                 = "${local.name}-web"
  user_pool_id                         = aws_cognito_user_pool.users.id
  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = ["https://${aws_cloudfront_distribution.web.domain_name}/"]
  logout_urls                          = ["https://${aws_cloudfront_distribution.web.domain_name}/"]
  prevent_user_existence_errors        = "ENABLED"
  enable_token_revocation              = true
  access_token_validity                = 15
  id_token_validity                    = 15
  refresh_token_validity               = 1
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
}
resource "aws_cognito_user_pool_domain" "login" {
  domain       = "${local.name}-${local.account}"
  user_pool_id = aws_cognito_user_pool.users.id
}
