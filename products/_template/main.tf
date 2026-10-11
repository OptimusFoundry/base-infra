# Template for a new subdomain project. Copy to products/<slug>/, replace every
# PROJECT_SLUG, pick an unused alb_rule_priority, then:
#
#   aws s3 mb s3://<slug>-terraform-state
#   terraform init && terraform apply
#
# The module covers edge and routing only: S3, CloudFront, DNS, ALB target group
# and listener rule. You still add, in this directory:
#   - an ECS task definition + service, wiring load_balancer.target_group_arn to
#     module.product.target_group_arn
#   - a manifest.tf, if the app reads /<slug>/manifest
#   - secrets.tf + a gitignored secrets.auto.tfvars for /<slug>/* SSM params
#
# Both are deliberately outside the module: their content is product-specific.

terraform {
  required_version = ">= 1.15.0"

  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 6.0" }
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 5.0" }
  }

  backend "s3" {
    bucket = "PROJECT_SLUG-terraform-state"
    key    = "state/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Stack     = "product"
      Product   = var.product
    }
  }
}

data "aws_ssm_parameter" "cloudflare_api_key" {
  name = "/cloudflare/api_key"
}

provider "cloudflare" {
  email   = var.cloudflare_email
  api_key = data.aws_ssm_parameter.cloudflare_api_key.value
}

data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = "protoapp-infra-terraform-state"
    key    = "state/terraform.tfstate"
    region = var.aws_region
  }
}

module "product" {
  source = "../../modules/product"

  product     = var.product
  domain      = "${var.product}.${data.terraform_remote_state.platform.outputs.zone_domain}"
  environment = var.environment
  tier        = "prototype"

  umbrella_zone_domain = data.terraform_remote_state.platform.outputs.zone_domain

  acm_certificate_arn     = data.terraform_remote_state.platform.outputs.acm_certificate_arn
  platform_alb_arn_suffix = data.terraform_remote_state.platform.outputs.alb_arn_suffix

  platform_alb_dns_name     = data.terraform_remote_state.platform.outputs.alb_dns_name
  platform_alb_listener_arn = data.terraform_remote_state.platform.outputs.alb_listener_http_arn
  origin_verify_secret      = data.terraform_remote_state.platform.outputs.origin_verify_secret
  platform_vpc_id           = data.terraform_remote_state.platform.outputs.vpc_id

  cloudflare_zone_id                  = data.terraform_remote_state.platform.outputs.cloudflare_zone_id
  cloudfront_cache_policy_id          = data.terraform_remote_state.platform.outputs.cloudfront_api_cache_policy_id
  cloudfront_origin_request_policy_id = data.terraform_remote_state.platform.outputs.cloudfront_api_origin_request_policy_id
  cloudfront_spa_function_arn         = data.terraform_remote_state.platform.outputs.cloudfront_spa_function_arn

  # Must be unique across all products. sjocamp 100, protoapp 200,
  # new projects from 300 in steps of 10. AWS rejects duplicates.
  alb_rule_priority = 300
}
