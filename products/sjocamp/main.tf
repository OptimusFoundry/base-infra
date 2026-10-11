terraform {
  required_version = ">= 1.15.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket = "sjocamp-terraform-state"
    key    = "state/terraform.tfstate"
    region = "us-east-1"
  }
}

module "product" {
  source = "../../modules/product"

  product     = var.product
  domain      = var.domain_name
  environment = var.environment
  tier        = "product"

  umbrella_zone_domain = data.terraform_remote_state.platform.outputs.zone_domain

  platform_alb_dns_name     = data.terraform_remote_state.platform.outputs.alb_dns_name
  platform_alb_listener_arn = data.terraform_remote_state.platform.outputs.alb_listener_http_arn
  origin_verify_secret      = data.terraform_remote_state.platform.outputs.origin_verify_secret
  platform_vpc_id           = data.terraform_remote_state.platform.outputs.vpc_id
  acm_certificate_arn       = aws_acm_certificate.ssl_cert.arn

  cloudflare_zone_id                  = var.cloudflare_zone_id
  cloudfront_cache_policy_id          = data.terraform_remote_state.platform.outputs.cloudfront_api_cache_policy_id
  cloudfront_origin_request_policy_id = data.terraform_remote_state.platform.outputs.cloudfront_api_origin_request_policy_id
  cloudfront_spa_function_arn         = data.terraform_remote_state.platform.outputs.cloudfront_spa_function_arn

  alb_rule_priority = var.alb_rule_priority

  alerts_topic_arn        = data.terraform_remote_state.platform.outputs.alerts_topic_arn
  platform_alb_arn_suffix = data.terraform_remote_state.platform.outputs.alb_arn_suffix

  # Live names — omitting any of these replaces the resource.
  s3_bucket_name    = "app.sjocamp.co-webapp"
  target_group_name = "sjocamp-api-tg"
  oac_name          = "sjocamp-webapp-oac"
  log_group_name    = "/aws/cloudfront/sjocamp-webapp"
}

moved {
  from = aws_s3_bucket.webapp_bucket
  to   = module.product.aws_s3_bucket.webapp
}

moved {
  from = aws_s3_bucket_public_access_block.webapp_bucket_public_access
  to   = module.product.aws_s3_bucket_public_access_block.webapp
}

moved {
  from = aws_s3_bucket_policy.webapp_bucket_policy
  to   = module.product.aws_s3_bucket_policy.webapp
}

moved {
  from = aws_cloudfront_origin_access_control.webapp_oac
  to   = module.product.aws_cloudfront_origin_access_control.webapp
}

moved {
  from = aws_cloudfront_distribution.webapp_distribution
  to   = module.product.aws_cloudfront_distribution.webapp
}

moved {
  from = aws_cloudwatch_log_group.cloudfront_logs
  to   = module.product.aws_cloudwatch_log_group.cloudfront
}

moved {
  from = aws_lb_target_group.api
  to   = module.product.aws_lb_target_group.api
}

moved {
  from = aws_lb_listener_rule.api
  to   = module.product.aws_lb_listener_rule.api
}

moved {
  from = cloudflare_dns_record.app_to_cloudfront
  to   = module.product.cloudflare_dns_record.app[0]
}

# aws_ssm_parameter.manifest is NOT moved into the module. The manifest
# assembles ECR/ECS/Sentry/landing-domain values that are irreducibly
# product-specific (the same reason the module owns no ECS task definition
# or service) — it stays in products/sjocamp/manifest.tf, unmoved, only
# repointing its two module-owned fields (webapp bucket id, CloudFront
# distribution id) to module.product outputs.
