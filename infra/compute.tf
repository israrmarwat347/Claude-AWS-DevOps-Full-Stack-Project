resource "aws_iam_role" "execution" {
  name                 = "${var.project}-runtime-${var.environment}-execution"
  permissions_boundary = var.runtime_boundary_arn
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow",
    Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole",
    Condition = { StringEquals = { "aws:SourceAccount" = local.account },
  ArnLike = { "aws:SourceArn" = "arn:aws:ecs:${var.aws_region}:${local.account}:*" } } }] })
}
resource "aws_iam_role_policy" "execution" {
  role = aws_iam_role.execution.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
    { Effect = "Allow", Action = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"],
    Resource = "arn:aws:ecr:${var.aws_region}:${local.account}:repository/${local.name}" },
    { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.app.arn}:*" }
  ] })
}
resource "aws_iam_role" "task" {
  name                 = "${var.project}-runtime-${var.environment}-task"
  permissions_boundary = var.runtime_boundary_arn
  assume_role_policy   = aws_iam_role.execution.assume_role_policy
}
resource "aws_iam_role_policy" "task" {
  role = aws_iam_role.task.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query", "dynamodb:DeleteItem"],
    Resource = aws_dynamodb_table.chat.arn },
    { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = data.aws_secretsmanager_secret.anthropic.arn }
  ] })
}
resource "aws_ecs_cluster" "main" {
  name = local.name
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}
resource "aws_ecs_task_definition" "api" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  volume { name = "tmp" }
  container_definitions = jsonencode([{
    name                   = "api", image = var.image_uri, essential = true, user = "10001:10001",
    readonlyRootFilesystem = true, stopTimeout = 120,
    linuxParameters        = { initProcessEnabled = true, capabilities = { drop = ["ALL"] } },
    mountPoints            = [{ sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }],
    portMappings           = [{ containerPort = 8443, protocol = "tcp" }],
    environment = [for k, v in {
      APP_ENV              = var.environment
      AWS_REGION           = var.aws_region
      TABLE_NAME           = aws_dynamodb_table.chat.name
      ANTHROPIC_SECRET_ARN = data.aws_secretsmanager_secret.anthropic.arn
      COGNITO_USER_POOL_ID = aws_cognito_user_pool.users.id
      COGNITO_CLIENT_ID    = aws_cognito_user_pool_client.web.id
      COGNITO_DOMAIN       = "https://${aws_cognito_user_pool_domain.login.domain}.auth.${var.aws_region}.amazoncognito.com"
      CLAUDE_MODEL         = var.claude_model
      RETENTION_DAYS       = tostring(var.retention_days)
      RELEASE_SHA          = var.release_sha
      LOCAL_AUTH           = "false"
      MOCK_CLAUDE          = "false"
    } : { name = k, value = v }],
    logConfiguration = { logDriver = "awslogs", options = {
      awslogs-group = aws_cloudwatch_log_group.app.name, awslogs-region = var.aws_region, awslogs-stream-prefix = "api"
    } },
    healthCheck = { command = ["CMD-SHELL", "python -c \"import ssl,urllib.request; urllib.request.urlopen('https://127.0.0.1:8443/api/health/live',context=ssl._create_unverified_context(),timeout=3)\""],
    interval = 30, timeout = 5, retries = 3, startPeriod = 30 }
  }])
}
resource "aws_ecs_service" "api" {
  name                               = local.name
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.api.arn
  desired_count                      = var.task_count
  launch_type                        = "FARGATE"
  platform_version                   = "1.4.0"
  health_check_grace_period_seconds  = 90
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  wait_for_steady_state              = true
  enable_ecs_managed_tags            = true
  propagate_tags                     = "SERVICE"
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 8443
  }
  lifecycle { ignore_changes = [desired_count] }
  depends_on = [aws_lb_listener_rule.cloudfront, aws_iam_role_policy.task, aws_iam_role_policy.execution,
  aws_route_table_association.private]
  timeouts {
    create = "25m"
    update = "25m"
  }
}
resource "aws_appautoscaling_target" "api" {
  max_capacity       = var.max_tasks
  min_capacity       = var.task_count
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}
resource "aws_appautoscaling_policy" "cpu" {
  name               = "${local.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  target_tracking_scaling_policy_configuration {
    predefined_metric_specification { predefined_metric_type = "ECSServiceAverageCPUUtilization" }
    target_value       = 60
    scale_in_cooldown  = 180
    scale_out_cooldown = 60
  }
}
