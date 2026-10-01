# Public status page (polymarket-bot CH-009): https://pmbot.protoapp.xyz
#
#   pmbot-site-<account>  Private S3 bucket. Only this CloudFront distribution may read it (OAC). The pmbot-status
#                         task writes status.json every 60 s; polymarket-bot's pmbot-site.yml (as pmbot-github-deploy)
#                         uploads index.html, scoreboard.json and assets/.
#   CloudFront            The platform's *.protoapp.xyz wildcard certificate; status.json is never cached at the edge.
#   pmbot-status          ECS service running `python -m sports.ops.status_page loop` on the collect image, /data
#                         mounted read-only, SPORTS_S3=off. Task role pmbot-status: PutObject status.json, nothing else.
#                         Created at desired count 0: its Terraform-registered revision carries the bootstrap image,
#                         which has no status_page; the README "Status page" step scales it to 1 after a deploy.
# The DNS record is products/pmbot/dns (owner-applied: it needs the Cloudflare key, which CD never reads).
# The task role is not named pmbot-task-*: those are the per-plane data roles plan_guard scope-checks (EP-031).

locals {
  site_domain = "pmbot.${data.terraform_remote_state.platform.outputs.zone_domain}"
  site_bucket = "pmbot-site-${local.account_id}"
  site_origin = "pmbot-site-s3"

  # AWS-managed CloudFront policies (fixed, documented ids), so a plan needs no cloudfront:List* call for them.
  cache_policy_optimized  = "658327ea-f89d-4fab-a63d-7e88639e58f6" # Managed-CachingOptimized
  cache_policy_disabled   = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # Managed-CachingDisabled
  security_headers_policy = "67f7725c-6f97-4210-82d7-5512b31e9d03" # Managed-SecurityHeadersPolicy

  # The writer's whole environment (plus PMBOT_GIT_SHA, injected by pmbot-deploy). Not local.common_env: the writer
  # never syncs /data (SPORTS_S3=off) and has no upload queue.
  status_env = {
    SPORTS_DATA_ROOT   = "/data"
    SPORTS_S3          = "off"
    STATUS_SITE_BUCKET = local.site_bucket
    AWS_REGION         = var.aws_region
    AWS_DEFAULT_REGION = var.aws_region
    PYTHONUNBUFFERED   = "1"
  }
}

# --- site bucket ---

resource "aws_s3_bucket" "site" {
  bucket = local.site_bucket
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket = aws_s3_bucket.site.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "CloudFrontReadsThroughOac"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.site.arn}/*"
        Condition = {
          StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.site.arn }
        }
      },
      {
        Sid       = "TlsOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.site.arn, "${aws_s3_bucket.site.arn}/*"]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.site]
}

# --- CloudFront ---

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "pmbot-site"
  description                       = "pmbot status page bucket (polymarket-bot CH-009)"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "pmbot status page (polymarket-bot CH-009)"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  aliases             = [local.site_domain]

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = local.site_origin
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    target_origin_id           = local.site_origin
    viewer_protocol_policy     = "redirect-to-https"
    compress                   = true
    cache_policy_id            = local.cache_policy_optimized
    response_headers_policy_id = local.security_headers_policy
  }

  # Rewritten every 60 s: never cached at the edge, so the page's age check sees the real age (CH-009 ruling 7).
  ordered_cache_behavior {
    path_pattern               = "/status.json"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    target_origin_id           = local.site_origin
    viewer_protocol_policy     = "redirect-to-https"
    compress                   = true
    cache_policy_id            = local.cache_policy_disabled
    response_headers_policy_id = local.security_headers_policy
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = data.terraform_remote_state.platform.outputs.acm_certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# --- pmbot-status service ---

resource "aws_cloudwatch_log_group" "status" {
  name              = "/ecs/pmbot/status"
  retention_in_days = 30
}

resource "aws_iam_role" "status" {
  name = "pmbot-status"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "status" {
  name = "pmbot-status"
  role = aws_iam_role.status.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PublishStatusJsonOnly"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.site.arn}/status.json"
      },
      {
        Sid    = "EcsExecChannels"
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_ecs_task_definition" "status" {
  family                   = "pmbot-status"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.status.arn

  container_definitions = jsonencode([{
    name              = "status"
    image             = "${local.registry}/${aws_ecr_repository.pmbot.name}:${var.image_tag}-collect"
    command           = ["python", "-m", "sports.ops.status_page", "loop"]
    essential         = true
    cpu               = 64
    memoryReservation = 192
    memory            = 512
    stopTimeout       = 30

    linuxParameters = {
      initProcessEnabled = true
    }

    mountPoints = [{
      sourceVolume  = "data"
      containerPath = "/data"
      readOnly      = true
    }]

    environment = [for key, value in local.status_env : { name = key, value = value }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.status.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "status"
      }
    }
  }])

  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  volume {
    name      = "data"
    host_path = "/data"
  }

  placement_constraints {
    type       = "memberOf"
    expression = local.placement_expression
  }
}

resource "aws_ecs_service" "status" {
  name            = "pmbot-status"
  cluster         = aws_ecs_cluster.pmbot.id
  task_definition = aws_ecs_task_definition.status.arn
  desired_count   = 0

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.pmbot.name
    weight            = 1
    base              = 1
  }

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  enable_execute_command             = true

  placement_constraints {
    type       = "memberOf"
    expression = local.placement_expression
  }

  depends_on = [aws_ecs_cluster_capacity_providers.pmbot]

  # desired_count: parked at 0 until the first deploy, then scaled by hand (README "Status page"); an apply never
  # undoes that. task_definition: polymarket-bot's pmbot-deploy owns the running revision (CH-008).
  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }
}

output "site_bucket_name" {
  value       = aws_s3_bucket.site.bucket
  description = "PMBOT_SITE_BUCKET repository variable in OptimusFoundry/polymarket-bot"
}

output "site_distribution_id" {
  value       = aws_cloudfront_distribution.site.id
  description = "PMBOT_SITE_DISTRIBUTION_ID repository variable in OptimusFoundry/polymarket-bot"
}

output "site_distribution_domain_name" {
  value       = aws_cloudfront_distribution.site.domain_name
  description = "CNAME target of the pmbot.protoapp.xyz record (products/pmbot/dns)"
}

output "site_domain" {
  value       = local.site_domain
  description = "The status page's hostname"
}

output "status_service_name" {
  value       = aws_ecs_service.status.name
  description = "ECS service that writes status.json (cluster pmbot)"
}
