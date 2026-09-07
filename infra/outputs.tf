output "site_url" { value = "https://${aws_cloudfront_distribution.web.domain_name}" }
output "frontend_bucket" { value = aws_s3_bucket.web.id }
output "distribution_id" { value = aws_cloudfront_distribution.web.id }
output "cluster_name" { value = aws_ecs_cluster.main.name }
output "service_name" { value = aws_ecs_service.api.name }
output "task_definition_arn" { value = aws_ecs_task_definition.api.arn }
output "anthropic_secret_arn" { value = data.aws_secretsmanager_secret.anthropic.arn }
output "user_pool_id" { value = aws_cognito_user_pool.users.id }
output "notification_topic_arn" { value = data.aws_sns_topic.notifications.arn }
output "dashboard_url" { value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${local.name}" }

output "deployed_image" { value = var.image_uri }
