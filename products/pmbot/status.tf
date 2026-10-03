# Public status page: https://pmbot.protoapp.xyz
#
#   pmbot-site-<account>  Private S3 bucket that only this CloudFront distribution may read (OAC). The
#                         pmbot-status task writes status.json every 60 s; polymarket-bot's pmbot-site.yml
#                         (as pmbot-github-deploy) uploads index.html, scoreboard.json and assets/.
#   CloudFront            On the platform's *.protoapp.xyz wildcard certificate; status.json is never cached.
#   pmbot-status          ECS service writing status.json from the data bucket (STATUS_SOURCE=s3: each family has
#                         its own volume, so no local /data holds everything). Task role pmbot-status may list
#                         sports/, read the maker's journal and flags, and PutObject status.json (its only write),
#                         plus the read-only ECS / CloudWatch (and, in ce mode, Cost Explorer) calls for the page's
#                         Services, Jobs, Alarms and Cost panels (EP-035). Parked at desired count 0; scaled by hand.
#
# Hand-built rather than modules/product: the module always creates an ALB target group and listener
# rule, and this site has no API.

locals {
  site_domain = "pmbot.${data.terraform_remote_state.platform.outputs.zone_domain}"
  site_bucket = "pmbot-site-${local.account_id}"
  site_origin = "pmbot-site-s3"

  # AWS-managed CloudFront policies (fixed, documented ids), so a plan needs no cloudfront:List* call for them.
  cache_policy_optimized  = "658327ea-f89d-4fab-a63d-7e88639e58f6" # Managed-CachingOptimized
  cache_policy_disabled   = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # Managed-CachingDisabled
  security_headers_policy = "67f7725c-6f97-4210-82d7-5512b31e9d03" # Managed-SecurityHeadersPolicy

  # The writer's whole environment (plus PMBOT_GIT_SHA, injected by pmbot-deploy). Not local.common_env:
  # it never syncs (SPORTS_S3=off) and reads the data bucket directly (STATUS_SOURCE=s3). EP-035: STATUS_AWS=on
  # turns on the read-only ECS and CloudWatch views; STATUS_COST_SOURCE picks the cost view; STATUS_CLUSTER is
  # the cluster the services run on (the writer has no default and refuses to start without it).
  status_env = {
    SPORTS_S3          = "off"
    STATUS_SOURCE      = "s3"
    SPORTS_S3_BUCKET   = var.data_bucket
    STATUS_SITE_BUCKET = local.site_bucket
    STATUS_AWS         = "on"
    STATUS_COST_SOURCE = var.status_cost_source
    STATUS_CLUSTER     = local.cluster_name
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

  # Rewritten every 60 s: never cached at the edge, so the page's age check sees the real age.
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

  # ListData / ReadTheMakerJournal feed the S3 mirror (STATUS_SOURCE=s3). EP-035 adds the writer's read-only
  # views, each a Describe/Get call. Scoping, and what a wrong guess costs (an AccessDenied makes that page
  # section `error`; it never widens anything or blanks the page):
  #   ecs:DescribeServices      this cluster's pmbot-* services only (resource-level supported); the cluster is
  #                             the shared ecs-cluster, so the scope keeps other products' services out.
  #   cloudwatch:GetMetricData  no resource-level support: "*".
  #   cloudwatch:DescribeAlarms no resource-level permissions: "*" (names and states only; the writer asks for
  #                             the pmbot- prefix).
  #   ce:GetCostAndUsage        no resource-level support: "*", and only while var.status_cost_source is "ce".
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "ListData"
          Effect   = "Allow"
          Action   = ["s3:ListBucket"]
          Resource = "arn:aws:s3:::${var.data_bucket}"
          Condition = {
            StringLike = { "s3:prefix" = ["sports/*"] }
          }
        },
        {
          Sid      = "ReadTheMakerJournal"
          Effect   = "Allow"
          Action   = ["s3:GetObject"]
          Resource = "arn:aws:s3:::${var.data_bucket}/sports/live/maker/*"
        },
        {
          # polymarket-bot CH-012: the comparison of paper variants reads scores/summary.json.
          Sid      = "ReadTheScores"
          Effect   = "Allow"
          Action   = ["s3:GetObject"]
          Resource = "arn:aws:s3:::${var.data_bucket}/sports/scores/*"
        },
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
        {
          Sid      = "DescribePmbotServices"
          Effect   = "Allow"
          Action   = ["ecs:DescribeServices"]
          Resource = "arn:aws:ecs:${var.aws_region}:${local.account_id}:service/${local.cluster_name}/pmbot-*"
        },
        {
          Sid      = "ReadPmbotMetrics"
          Effect   = "Allow"
          Action   = ["cloudwatch:GetMetricData"]
          Resource = "*"
        },
        {
          Sid      = "DescribePmbotAlarms"
          Effect   = "Allow"
          Action   = ["cloudwatch:DescribeAlarms"]
          Resource = "*"
        },
      ],
      var.status_cost_source == "ce" ? [
        {
          Sid      = "ReadPmbotCost"
          Effect   = "Allow"
          Action   = ["ce:GetCostAndUsage"]
          Resource = "*"
        },
      ] : [],
    )
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
}

resource "aws_ecs_service" "status" {
  name                 = "pmbot-status"
  cluster              = local.cluster_id
  launch_type          = "EC2"
  task_definition      = aws_ecs_task_definition.status.arn
  desired_count        = 0
  force_new_deployment = true

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  enable_execute_command             = true

  # desired_count: scaled by hand; an apply never undoes that. task_definition: pmbot-deploy owns
  # the running revision.
  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }
}

# --- DNS ---

resource "cloudflare_dns_record" "site" {
  zone_id = data.terraform_remote_state.platform.outputs.cloudflare_zone_id
  name    = local.site_domain
  type    = "CNAME"
  content = aws_cloudfront_distribution.site.domain_name
  ttl     = 1
  proxied = false
}
