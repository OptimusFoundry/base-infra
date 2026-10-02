output "ecr_repository_url" {
  value = aws_ecr_repository.pmbot.repository_url
}

output "github_push_role_arn" {
  value       = aws_iam_role.github_push.arn
  description = "PMBOT_ECR_PUSH_ROLE_ARN repository variable in polymarket-bot"
}

output "github_deploy_role_arn" {
  value       = aws_iam_role.github_deploy.arn
  description = "PMBOT_DEPLOY_ROLE_ARN repository variable in polymarket-bot"
}

output "service_names" {
  value = { for key, service in aws_ecs_service.svc : key => service.name }
}

output "log_group_names" {
  value = { for key, group in aws_cloudwatch_log_group.svc : key => group.name }
}

output "site_bucket_name" {
  value       = aws_s3_bucket.site.bucket
  description = "PMBOT_SITE_BUCKET repository variable in polymarket-bot"
}

output "site_distribution_id" {
  value       = aws_cloudfront_distribution.site.id
  description = "PMBOT_SITE_DISTRIBUTION_ID repository variable in polymarket-bot"
}

output "site_domain" {
  value = local.site_domain
}

output "status_service_name" {
  value = aws_ecs_service.status.name
}
