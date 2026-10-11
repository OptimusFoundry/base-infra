output "alb_dns_name" {
  value       = aws_lb.k8s_alb.dns_name
  description = "DNS name of the shared ALB"
}

output "alb_arn" {
  value       = aws_lb.k8s_alb.arn
  description = "ARN of the shared ALB"
}

output "alb_zone_id" {
  value       = aws_lb.k8s_alb.zone_id
  description = "Hosted zone ID of the shared ALB (for Route 53 alias records)"
}

output "alb_listener_http_arn" {
  value       = aws_lb_listener.http_listener.arn
  description = "ARN of the shared HTTP :80 listener; products attach their own listener rules to this"
}

output "vpc_id" {
  value       = aws_vpc.base_vpc.id
  description = "Shared VPC ID"
}

output "public_subnet_ids" {
  value       = [aws_subnet.public_subnet_a.id, aws_subnet.public_subnet_b.id]
  description = "Public subnet IDs (for ECS tasks, ALB)"
}

output "private_subnet_ids" {
  value       = [aws_subnet.private_subnet_a.id, aws_subnet.private_subnet_b.id]
  description = "Private subnet IDs (for RDS and other internal-only resources)"
}

output "ecs_cluster_id" {
  value       = aws_ecs_cluster.ecs_cluster.id
  description = "Shared ECS cluster ID (products attach services here)"
}

output "ecs_cluster_name" {
  value       = aws_ecs_cluster.ecs_cluster.name
  description = "Shared ECS cluster name"
}

output "ecs_service_role_name" {
  value       = aws_iam_role.ecs_service_role.name
  description = "IAM role for ECS services to register with the ALB"
}

output "ecs_task_role_arn" {
  value       = aws_iam_role.ecs_task_role.arn
  description = "IAM task execution role ARN"
}

output "kafka_bootstrap_servers" {
  value       = "kafka.base-services.local:9092"
  description = "Internal Kafka endpoint (shared)"
}

output "cloudfront_api_cache_policy_id" {
  value       = aws_cloudfront_cache_policy.api_no_cache.id
  description = "Shared no-cache policy for /api/* behaviours"
}

output "cloudfront_api_origin_request_policy_id" {
  value       = aws_cloudfront_origin_request_policy.api_origin_request.id
  description = "Shared origin-request policy forwarding viewer headers to the API"
}

output "cloudfront_spa_function_arn" {
  value       = aws_cloudfront_function.spa_routing.arn
  description = "Shared viewer-request function rewriting SPA routes to index.html"
}

output "acm_certificate_arn" {
  value       = aws_acm_certificate.wildcard.arn
  description = "Wildcard cert covering protoapp.xyz and *.protoapp.xyz; used by every product CloudFront"
}

output "cloudflare_zone_id" {
  value       = var.cloudflare_zone_id
  description = "Cloudflare zone ID for the umbrella zone"
}

output "zone_domain" {
  value       = var.zone_domain
  description = "Umbrella domain hosting all product subdomains"
}

output "alerts_topic_arn" {
  value       = aws_sns_topic.alerts.arn
  description = "Shared SNS topic for product alarms; consumed by modules/product"
}

output "alb_arn_suffix" {
  value       = aws_lb.k8s_alb.arn_suffix
  description = "ALB ARN suffix for CloudWatch dimensions. The alb_arn output is the full ARN and is NOT usable as a dimension."
}

output "origin_verify_secret" {
  value       = random_password.origin_verify.result
  description = "Value CloudFront sends as X-Origin-Verify and each product's ALB rule requires"
  sensitive   = true
}
