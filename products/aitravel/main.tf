# aitravel — the AITravel iOS app's Go API (OptimusFoundry/AITravel, base-server/)
# on the umbrella zone.
#
# Prototype tier: serves aitravel.protoapp.xyz on the platform wildcard cert,
# 7-day logs, no target-group alarms. No name overrides — this stack is new, so
# every resource takes the module convention.
#
# The client is a native iOS app, so the module's webapp bucket + CloudFront
# serve nothing but `/api/*` for now; the SPA origin stays empty.

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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  # Follows the <slug>-terraform-state convention (products/_template/main.tf).
  backend "s3" {
    bucket = "aitravel-terraform-state"
    key    = "state/terraform.tfstate"
    region = "us-east-1"
  }
}

module "product" {
  source = "../../modules/product"

  product     = var.product
  domain      = "${var.product}.${data.terraform_remote_state.platform.outputs.zone_domain}"
  environment = var.environment
  tier        = "prototype"

  umbrella_zone_domain = data.terraform_remote_state.platform.outputs.zone_domain

  platform_alb_dns_name     = data.terraform_remote_state.platform.outputs.alb_dns_name
  platform_alb_listener_arn = data.terraform_remote_state.platform.outputs.alb_listener_http_arn
  platform_vpc_id           = data.terraform_remote_state.platform.outputs.vpc_id
  acm_certificate_arn       = data.terraform_remote_state.platform.outputs.acm_certificate_arn

  cloudflare_zone_id                  = data.terraform_remote_state.platform.outputs.cloudflare_zone_id
  cloudfront_cache_policy_id          = data.terraform_remote_state.platform.outputs.cloudfront_api_cache_policy_id
  cloudfront_origin_request_policy_id = data.terraform_remote_state.platform.outputs.cloudfront_api_origin_request_policy_id
  cloudfront_spa_function_arn         = data.terraform_remote_state.platform.outputs.cloudfront_spa_function_arn

  platform_alb_arn_suffix = data.terraform_remote_state.platform.outputs.alb_arn_suffix

  # Account-wide unique. sjocamp 100, meerkat 200, orca 300, aitravel 310.
  alb_rule_priority = var.alb_rule_priority

  # Gemini tool-loop day generation can run past CloudFront's 30 s default
  # before the first byte comes back; 60 is the ceiling without a quota raise.
  api_origin_read_timeout = 60
}
