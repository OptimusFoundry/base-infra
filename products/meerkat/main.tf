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

  backend "s3" {
    bucket = "protoapp-terraform-state"
    key    = "state/terraform.tfstate"
    region = "us-east-1"
  }
}

module "product" {
  source = "../../modules/product"

  product     = var.product
  domain      = var.domain_name
  environment = var.environment
  tier        = "prototype"

  umbrella_zone_domain = data.terraform_remote_state.platform.outputs.zone_domain

  platform_alb_dns_name     = data.terraform_remote_state.platform.outputs.alb_dns_name
  platform_alb_listener_arn = data.terraform_remote_state.platform.outputs.alb_listener_http_arn
  origin_verify_secret      = data.terraform_remote_state.platform.outputs.origin_verify_secret
  platform_vpc_id           = data.terraform_remote_state.platform.outputs.vpc_id
  acm_certificate_arn       = data.terraform_remote_state.platform.outputs.acm_certificate_arn

  cloudflare_zone_id                  = var.cloudflare_zone_id
  cloudfront_cache_policy_id          = data.terraform_remote_state.platform.outputs.cloudfront_api_cache_policy_id
  cloudfront_origin_request_policy_id = data.terraform_remote_state.platform.outputs.cloudfront_api_origin_request_policy_id
  cloudfront_spa_function_arn         = data.terraform_remote_state.platform.outputs.cloudfront_spa_function_arn

  alb_rule_priority = 200

  platform_alb_arn_suffix = data.terraform_remote_state.platform.outputs.alb_arn_suffix

  # meerkat serves exactly one hostname now. The apex and www aliases were
  # dropped when it moved off protoapp.xyz.
  extra_aliases = []

  # Legacy hardcoded names. Every one of these forces replacement if omitted:
  # the distribution would take ~20 minutes to rebuild.
  #
  # s3_bucket_name is deliberately NOT overridden: meerkat takes the module
  # convention, protoapp-meerkat-webapp. The old protoapp.xyz-webapp named a
  # domain meerkat no longer serves. Renaming cost one bucket replacement,
  # which is cheap because the contents are build output CI regenerates.
  target_group_name = "ecs-target-group"
  oac_name          = "webapp-oac"
  log_group_name    = "/aws/cloudfront/webapp"
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

# NOT a `moved` block, deliberately — do not "fix" this back into one, it
# will not work. `moved` requires the from/to resource TYPE to match exactly;
# it compares type names, not provider schemas. aws_alb_target_group and
# aws_lb_target_group are the same underlying AWS resource as far as the
# provider is concerned, but they are two distinct registered type names, so
# Terraform Core treats this as a cross-type move. Confirmed by reproducing
# it on Terraform v1.7.5:
#
#   Error: Resource type mismatch
#   This statement declares a move from aws_alb_target_group.ecs_target to
#   module.product.aws_lb_target_group.api, which is a resource of a
#   different type.
#
# Cross-type moves only work when the provider implements MoveState for that
# pair (Terraform >=1.8), which the AWS provider does not for this alias.
# `removed { lifecycle { destroy = false } }` + `import` is the correct
# native substitute: it drops the old address from state without touching
# the real target group, then re-associates the same live resource (verified
# ARN below, matching both prior state and the ARN actually attached to the
# listener rule's forward action) at the new address/type. Like `moved`, it
# is purely declarative and previewed by `plan` — nothing happens to the real
# target group until `apply`.
removed {
  from = aws_alb_target_group.ecs_target
  lifecycle {
    destroy = false
  }
}

import {
  to = module.product.aws_lb_target_group.api
  id = "arn:aws:elasticloadbalancing:us-east-1:339713122183:targetgroup/ecs-target-group/4ca6ff25e493d597"
}

moved {
  from = aws_lb_listener_rule.alb_listener_rule_api_http
  to   = module.product.aws_lb_listener_rule.api
}

moved {
  from = cloudflare_dns_record.root_to_cloudfront
  to   = module.product.cloudflare_dns_record.app[0]
}

# aws_ssm_parameter.manifest is NOT moved into the module. The manifest
# assembles ECR/ECS/capture-worker values that are irreducibly
# product-specific (the same reason the module owns no ECS task definition
# or service) — it stays in products/meerkat/manifest.tf, unmoved, only
# repointing its two module-owned fields (webapp bucket id, CloudFront
# distribution id) to module.product outputs.
