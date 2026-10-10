resource "aws_cloudwatch_log_group" "api" {
  name              = "/${var.product}/api"
  retention_in_days = module.product.log_retention_days
}

# DB connection env shared by the API and the migrator (migrator.tf).
# agentworks connects as its own role, like aitravel — see secrets.tf and
# README.md "Database".
locals {
  db_environment = [
    { name = "DB_HOST", value = data.aws_ssm_parameter.rds_host.value },
    { name = "DB_PORT", value = data.aws_ssm_parameter.rds_port.value },
    { name = "DB_NAME", value = aws_ssm_parameter.db_name.value },
    { name = "DB_USERNAME", value = aws_ssm_parameter.db_username.value },
    { name = "DB_PASSWORD", value = aws_ssm_parameter.db_password.value },
  ]
}

resource "aws_ecs_task_definition" "api" {
  family             = "${var.product}-api"
  execution_role_arn = data.terraform_remote_state.platform.outputs.ecs_task_role_arn
  # Only for KMS (kms.tf). Unlike aitravel, which needs no task role.
  task_role_arn = aws_iam_role.api_task.arn
  network_mode  = "bridge"

  # Hosts are Graviton (t4g) — image is built linux/arm64 in CI.
  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([
    {
      name              = var.container_name_api
      image             = "${aws_ecr_repository.api.repository_url}:${var.api_image_tag}"
      cpu               = var.api_container_cpu
      memoryReservation = var.api_container_memory_reservation
      memory            = var.api_container_memory
      essential         = true

      # Room for in-flight Kafka consumers and HTTP requests to drain on deploy.
      stopTimeout = 60

      portMappings = [
        { containerPort = 80, hostPort = 0 }
      ]

      # /health is at the root, not under /api. startPeriod covers the
      # boot-time Kafka topic creation and the DB pool warm-up.
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:80/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }

      # Plain `environment`, like every product here: the platform ecsTaskRole
      # has no ssm:GetParameters, so the secrets/valueFrom route is not
      # available.
      environment = concat(local.db_environment, [
        { name = "GO_ENV", value = var.environment },
        { name = "GIN_MODE", value = "release" },
        { name = "APP_SERVER_PORT", value = "80" },

        { name = "AUTH_JWT_SECRET", value = data.aws_ssm_parameter.auth_jwt_secret.value },
        { name = "AUTH_GOOGLE_OAUTH_CLIENT_ID", value = data.aws_ssm_parameter.auth_google_oauth_client_id.value },
        { name = "AUTH_GOOGLE_OAUTH_CLIENT_SECRET", value = data.aws_ssm_parameter.auth_google_oauth_client_secret.value },
        { name = "AUTH_GOOGLE_REDIRECT_URI", value = aws_ssm_parameter.auth_google_redirect_uri.value },
        { name = "APP_WEBAPP_URI", value = aws_ssm_parameter.app_webapp_uri.value },
        # Hook and GitHub-callback URLs are built from this; the default is
        # http://localhost:<port>.
        { name = "PUBLIC_BASE_URL", value = aws_ssm_parameter.app_webapp_uri.value },

        { name = "PAYMENTS_STRIPE_SECRET_KEY", value = data.aws_ssm_parameter.platform_stripe_secret_key.value },
        { name = "PAYMENTS_STRIPE_WEBHOOK_SECRET", value = data.aws_ssm_parameter.payments_stripe_webhook_secret.value },

        { name = "EMAIL_RESEND_API_KEY", value = data.aws_ssm_parameter.platform_resend_api_key.value },
        { name = "EMAIL_RESEND_WEBHOOK_SECRET", value = data.aws_ssm_parameter.email_resend_webhook_secret.value },
        { name = "EMAIL_SENDER_ADDRESS", value = data.aws_ssm_parameter.email_sender_address.value },

        # Stamped on Stripe objects and returned by GET /health — must equal
        # the slug.
        { name = "APP_PRODUCT_NAME", value = var.product },

        # Production refuses a local SECRETS_KEY; the task role (kms.tf) holds
        # the grant. AWS_REGION is what the SDK client is built with.
        { name = "SECRETS_KMS_KEY_ID", value = aws_kms_key.secrets.arn },
        { name = "AWS_REGION", value = var.aws_region },
        { name = "GATEWAY_TOKEN_KEY", value = data.aws_ssm_parameter.gateway_token_key.value },

        { name = "STORAGE_TYPE", value = aws_ssm_parameter.storage_type.value },
        { name = "STORAGE_S3_BUCKET", value = aws_s3_bucket.media.id },
        { name = "STORAGE_S3_REGION", value = var.aws_region },
        { name = "STORAGE_S3_ACCESS_KEY_ID", value = aws_iam_access_key.media.id },
        { name = "STORAGE_S3_SECRET_ACCESS_KEY", value = aws_iam_access_key.media.secret },
        { name = "STORAGE_PUBLIC_URL_BASE", value = aws_ssm_parameter.storage_public_url_base.value },

        # Topic and group names are slug-prefixed: the broker is shared, and two
        # products in one consumer group would steal each other's messages. The
        # server's defaults (webhook-events / webhook-consumers) are not. Its
        # KAFKA_TOPIC_* defaults are already agentworks.*, and
        # resend.email.events.v1 is hardcoded — README.md "Kafka".
        { name = "EVENTS_BROKERS", value = data.terraform_remote_state.platform.outputs.kafka_bootstrap_servers },
        { name = "EVENTS_TOPIC", value = "${var.product}.webhook-events" },
        { name = "EVENTS_CONSUMER_GROUP", value = "${var.product}.webhook-consumers" },
        { name = "KAFKA_PARTITIONS", value = tostring(var.kafka_partitions) },
      ])

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.api.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = var.container_name_api
        }
      }
    }
  ])
}

resource "aws_ecs_service" "api" {
  name            = var.service_name_api
  cluster         = data.terraform_remote_state.platform.outputs.ecs_cluster_id
  desired_count   = var.api_desired_count
  launch_type     = "EC2"
  task_definition = aws_ecs_task_definition.api.arn
  iam_role        = data.terraform_remote_state.platform.outputs.ecs_service_role_name

  load_balancer {
    container_name   = var.container_name_api
    container_port   = 80
    target_group_arn = module.product.target_group_arn
  }

  depends_on = [module.product]
}
