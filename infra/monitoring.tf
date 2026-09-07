resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.name}"
  retention_in_days = 30
}
resource "aws_cloudwatch_log_group" "flow" {
  name              = "/vpc/${local.name}"
  retention_in_days = 14
}
resource "aws_iam_role" "flow" {
  name                 = "${var.project}-runtime-${var.environment}-flow"
  permissions_boundary = var.runtime_boundary_arn
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow",
    Principal = { Service = "vpc-flow-logs.amazonaws.com" }, Action = "sts:AssumeRole",
  Condition = { StringEquals = { "aws:SourceAccount" = local.account } } }] })
}
resource "aws_iam_role_policy" "flow" {
  role = aws_iam_role.flow.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["logs:DescribeLogGroups"], Resource = "*" },
    { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"], Resource = "${aws_cloudwatch_log_group.flow.arn}:*" }
  ] })
}
resource "aws_flow_log" "main" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"
  log_destination = aws_cloudwatch_log_group.flow.arn
  iam_role_arn    = aws_iam_role.flow.arn
  depends_on      = [aws_iam_role_policy.flow]
}
data "aws_sns_topic" "notifications" { name = "${local.name}-notifications" }
resource "aws_cloudwatch_metric_alarm" "errors" {
  alarm_name          = "${local.name}-alb-errors"
  alarm_description   = "Backend 5xx responses; inspect request IDs in application logs"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = { LoadBalancer = aws_lb.api.arn_suffix }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [data.aws_sns_topic.notifications.arn]
  ok_actions          = [data.aws_sns_topic.notifications.arn]
}
resource "aws_cloudwatch_metric_alarm" "healthy" {
  alarm_name          = "${local.name}-no-healthy-targets"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { LoadBalancer = aws_lb.api.arn_suffix, TargetGroup = aws_lb_target_group.api.arn_suffix }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [data.aws_sns_topic.notifications.arn]
}
resource "aws_cloudwatch_log_metric_filter" "chat_errors" {
  name           = "${local.name}-chat-errors"
  log_group_name = aws_cloudwatch_log_group.app.name
  pattern        = "{ $.event = \"chat_error\" }"
  metric_transformation {
    name          = "ChatErrors"
    namespace     = local.name
    value         = "1"
    default_value = 0
  }
}
resource "aws_cloudwatch_metric_alarm" "chat_errors" {
  alarm_name          = "${local.name}-stream-errors"
  namespace           = local.name
  metric_name         = "ChatErrors"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [data.aws_sns_topic.notifications.arn]
}
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = local.name
  dashboard_body = jsonencode({ widgets = [
    { type = "metric", x = 0, y = 0, width = 12, height = 6, properties = {
      title = "Service utilization", region = var.aws_region, period = 60, stat = "Average",
      metrics = [["AWS/ECS", "CPUUtilization", "ClusterName", local.name, "ServiceName", local.name],
    ["AWS/ECS", "MemoryUtilization", "ClusterName", local.name, "ServiceName", local.name]] } },
    { type = "metric", x = 12, y = 0, width = 12, height = 6, properties = {
      title = "Backend and stream errors", region = var.aws_region, period = 60, stat = "Sum",
      metrics = [["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", aws_lb.api.arn_suffix],
    [local.name, "ChatErrors"]] } }
  ] })
}
resource "aws_wafv2_web_acl" "api" {
  count = var.enable_waf ? 1 : 0
  name  = local.name
  scope = "REGIONAL"
  default_action {
    allow {}
  }
  rule {
    name     = "ip-rate-limit"
    priority = 1
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 1000
        aggregate_key_type = "FORWARDED_IP"
        forwarded_ip_config {
          header_name       = "X-Forwarded-For"
          fallback_behavior = "MATCH"
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name}-ip-rate"
      sampled_requests_enabled   = false
    }
  }
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = local.name
    sampled_requests_enabled   = false
  }
}
resource "aws_wafv2_web_acl_association" "api" {
  count        = var.enable_waf ? 1 : 0
  resource_arn = aws_lb.api.arn
  web_acl_arn  = aws_wafv2_web_acl.api[0].arn
}
