resource "random_password" "origin" {
  length  = 48
  special = false
}
resource "aws_acm_certificate" "origin" {
  domain_name       = local.origin_host
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}
resource "aws_route53_record" "certificate" {
  for_each = { for o in aws_acm_certificate.origin.domain_validation_options : o.domain_name => o }
  zone_id  = var.route53_zone_id
  name     = each.value.resource_record_name
  type     = each.value.resource_record_type
  records  = [each.value.resource_record_value]
  ttl      = 60
}
resource "aws_acm_certificate_validation" "origin" {
  certificate_arn         = aws_acm_certificate.origin.arn
  validation_record_fqdns = [for r in aws_route53_record.certificate : r.fqdn]
}
resource "aws_lb" "api" {
  name                       = local.name
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = aws_subnet.public[*].id
  idle_timeout               = 150
  drop_invalid_header_fields = true
  enable_deletion_protection = var.environment == "prod"
  access_logs {
    bucket  = aws_s3_bucket.logs.id
    prefix  = "alb"
    enabled = true
  }
  depends_on = [aws_s3_bucket_policy.logs]
}
resource "aws_lb_target_group" "api" {
  name                 = local.name
  port                 = 8443
  protocol             = "HTTPS"
  target_type          = "ip"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 150
  health_check {
    enabled             = true
    path                = "/api/health/live"
    protocol            = "HTTPS"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.api.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.origin.certificate_arn
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Access denied"
      status_code  = "403"
    }
  }
}
resource "aws_lb_listener_rule" "cloudfront" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 1
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [random_password.origin.result]
    }
  }
}
resource "aws_route53_record" "origin" {
  zone_id = var.route53_zone_id
  name    = local.origin_host
  type    = "A"
  alias {
    name                   = aws_lb.api.dns_name
    zone_id                = aws_lb.api.zone_id
    evaluate_target_health = false
  }
}
resource "aws_s3_bucket" "web" {
  bucket        = "${local.name}-${local.account}-web"
  force_destroy = false
}
resource "aws_s3_bucket" "logs" {
  bucket        = "${local.name}-${local.account}-logs"
  force_destroy = false
}
resource "aws_s3_bucket_public_access_block" "web" {
  bucket                  = aws_s3_bucket.web.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_server_side_encryption_configuration" "private" {
  for_each = { web = aws_s3_bucket.web.id, logs = aws_s3_bucket.logs.id }
  bucket   = each.value
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
resource "aws_s3_bucket_versioning" "private" {
  for_each = { web = aws_s3_bucket.web.id, logs = aws_s3_bucket.logs.id }
  bucket   = each.value
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    id     = "expire-logs"
    status = "Enabled"
    filter {}
    expiration { days = 90 }
    noncurrent_version_expiration { noncurrent_days = 30 }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}
resource "aws_s3_bucket_lifecycle_configuration" "web" {
  bucket = aws_s3_bucket.web.id
  rule {
    id     = "old-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration { noncurrent_days = 90 }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}
resource "aws_s3_bucket_logging" "web" {
  bucket        = aws_s3_bucket.web.id
  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "s3/"
}
resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Sid = "TLSOnly", Effect = "Deny", Principal = "*", Action = "s3:*",
    Resource = [aws_s3_bucket.logs.arn, "${aws_s3_bucket.logs.arn}/*"], Condition = { Bool = { "aws:SecureTransport" = "false" } } },
    { Effect = "Allow", Principal = { Service = "logdelivery.elasticloadbalancing.amazonaws.com" },
    Action = "s3:PutObject", Resource = "${aws_s3_bucket.logs.arn}/alb/AWSLogs/${local.account}/*" },
    { Effect = "Allow", Principal = { Service = "logging.s3.amazonaws.com" }, Action = "s3:PutObject",
      Resource = "${aws_s3_bucket.logs.arn}/s3/*", Condition = { StringEquals = { "aws:SourceAccount" = local.account },
    ArnLike = { "aws:SourceArn" = aws_s3_bucket.web.arn } } }
  ] })
}
resource "aws_cloudfront_origin_access_control" "web" {
  name                              = local.name
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}
data "aws_cloudfront_cache_policy" "static" { name = "Managed-CachingOptimized" }
data "aws_cloudfront_cache_policy" "api" { name = "Managed-CachingDisabled" }
data "aws_cloudfront_origin_request_policy" "api" { name = "Managed-AllViewerExceptHostHeader" }
resource "aws_cloudfront_response_headers_policy" "security" {
  name = local.name
  security_headers_config {
    content_type_options { override = true }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "no-referrer"
      override        = true
    }
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      override                   = true
    }
    content_security_policy {
      content_security_policy = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self' https://cognito-idp.${var.aws_region}.amazonaws.com https://${aws_cognito_user_pool_domain.login.domain}.auth.${var.aws_region}.amazoncognito.com; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self' https://${aws_cognito_user_pool_domain.login.domain}.auth.${var.aws_region}.amazoncognito.com"
      override                = true
    }
  }
}
# Replace viewer-supplied X-Forwarded-For before the ALB WAF reads its first IP.
resource "aws_cloudfront_function" "client_ip" {
  name    = "${local.name}-client-ip"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = <<-JS
    function handler(event) {
      var request = event.request;
      request.headers['x-forwarded-for'] = { value: event.viewer.ip };
      return request;
    }
  JS
}
resource "aws_cloudfront_distribution" "web" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  http_version        = "http2and3"
  origin {
    domain_name              = aws_s3_bucket.web.bucket_regional_domain_name
    origin_id                = "static"
    origin_access_control_id = aws_cloudfront_origin_access_control.web.id
  }
  origin {
    domain_name = aws_route53_record.origin.fqdn
    origin_id   = "api"
    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origin.result
    }
    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "https-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 60
      origin_keepalive_timeout = 5
    }
  }
  default_cache_behavior {
    target_origin_id           = "static"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.static.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
  }
  ordered_cache_behavior {
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.client_ip.arn
    }
    path_pattern               = "/api/*"
    target_origin_id           = "api"
    viewer_protocol_policy     = "https-only"
    allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = false
    cache_policy_id            = data.aws_cloudfront_cache_policy.api.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.api.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
  }
  viewer_certificate { cloudfront_default_certificate = true }
  restrictions {
    geo_restriction { restriction_type = "none" }
  }
  depends_on = [aws_acm_certificate_validation.origin]
}
resource "aws_s3_bucket_policy" "web" {
  bucket = aws_s3_bucket.web.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Principal = { Service = "cloudfront.amazonaws.com" }, Action = "s3:GetObject",
    Resource = "${aws_s3_bucket.web.arn}/*", Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.web.arn } } },
    { Effect = "Deny", Principal = "*", Action = "s3:*", Resource = [aws_s3_bucket.web.arn, "${aws_s3_bucket.web.arn}/*"],
    Condition = { Bool = { "aws:SecureTransport" = "false" } } }
  ] })
}
