resource "aws_cloudwatch_log_group" "ecs_log_group" {
  name              = "${var.container_name_api}-logs"
  retention_in_days = module.product.log_retention_days
}

resource "aws_ecs_service" "ecs_service" {
  name                 = var.service_name_api
  cluster              = data.terraform_remote_state.platform.outputs.ecs_cluster_id
  desired_count        = 1
  launch_type          = "EC2"
  task_definition      = aws_ecs_task_definition.task_definition.arn
  iam_role             = data.terraform_remote_state.platform.outputs.ecs_service_role_name
  force_new_deployment = true

  load_balancer {
    container_name   = var.container_name_api
    container_port   = 80
    target_group_arn = module.product.target_group_arn
  }

  depends_on = [module.product]
}

resource "aws_ecs_task_definition" "task_definition" {
  family             = "base-server"
  execution_role_arn = data.terraform_remote_state.platform.outputs.ecs_task_role_arn
  network_mode       = "bridge"

  # Hosts are Graviton (t4g) — image is built linux/arm64 in CI.
  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([
    {
      name  = var.container_name_api
      image = "${data.aws_ecr_repository.api.repository_url}:${var.api_image_tag}"
      // Go binary sits at ~10 MB RSS and <1% of 1 vCPU under current load; old
      // cpu=256 / memory=256 was ~150× overprovisioned on both axes.
      cpu               = 64
      memoryReservation = 48
      memory            = 128
      essential         = true

      portMappings = [
        {
          containerPort = 80
          hostPort      = 0
        }
      ]

      healthCheck = {
        command = [
          "CMD-SHELL",
          "curl -f http://localhost:80/health || exit 1"
        ]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 2
      }

      environment = [
        { name = "GO_ENV", value = var.environment },
        { name = "GIN_MODE", value = "release" },
        { name = "DB_HOST", value = data.aws_ssm_parameter.rds_host.value },
        { name = "DB_USERNAME", value = data.aws_ssm_parameter.platform_db_username.value },
        { name = "DB_PASSWORD", value = data.aws_ssm_parameter.platform_db_password.value },
        { name = "DB_NAME", value = data.aws_ssm_parameter.db_name.value },
        { name = "DB_PORT", value = data.aws_ssm_parameter.rds_port.value },
        { name = "AUTH_JWT_SECRET", value = data.aws_ssm_parameter.auth_jwt_secret.value },
        { name = "AUTH_GOOGLE_OAUTH_CLIENT_ID", value = data.aws_ssm_parameter.auth_google_oauth_client_id.value },
        { name = "AUTH_GOOGLE_OAUTH_CLIENT_SECRET", value = data.aws_ssm_parameter.auth_google_oauth_client_secret.value },
        { name = "AUTH_GOOGLE_REDIRECT_URI", value = data.aws_ssm_parameter.auth_google_redirect_uri.value },
        { name = "APP_WEBAPP_URI", value = data.aws_ssm_parameter.app_webapp_uri.value },
        { name = "APP_SERVER_PORT", value = "80" },
        { name = "PAYMENTS_STRIPE_SECRET_KEY", value = data.aws_ssm_parameter.platform_stripe_secret_key.value },
        { name = "PAYMENTS_STRIPE_WEBHOOK_SECRET", value = data.aws_ssm_parameter.payments_stripe_webhook_secret.value },
        { name = "EMAIL_RESEND_API_KEY", value = data.aws_ssm_parameter.platform_resend_api_key.value },
        { name = "EMAIL_SENDER_ADDRESS", value = data.aws_ssm_parameter.email_sender_address.value },
        { name = "AI_GEMINI_API_KEY", value = data.aws_ssm_parameter.platform_gemini_api_key.value },
        { name = "AI_OPENAI_API_KEY", value = data.aws_ssm_parameter.platform_openai_api_key.value },
        { name = "EVENTS_BROKERS", value = data.terraform_remote_state.platform.outputs.kafka_bootstrap_servers },
        { name = "AUTH_TURNSTILE_SECRET_KEY", value = data.aws_ssm_parameter.platform_turnstile_secret_key.value },
        { name = "APP_PRODUCT_NAME", value = var.product },

        # Social platform + integration credentials
        { name = "AUTH_OAUTH_REDIRECT_BASE", value = data.aws_ssm_parameter.auth_oauth_redirect_base.value },
        { name = "SOCIAL_X_API_KEY", value = data.aws_ssm_parameter.social_x_api_key.value },
        { name = "SOCIAL_X_API_SECRET", value = data.aws_ssm_parameter.social_x_api_secret.value },
        { name = "SOCIAL_LINKEDIN_CLIENT_ID", value = data.aws_ssm_parameter.social_linkedin_client_id.value },
        { name = "SOCIAL_LINKEDIN_CLIENT_SECRET", value = data.aws_ssm_parameter.social_linkedin_client_secret.value },
        { name = "SOCIAL_META_APP_ID", value = data.aws_ssm_parameter.social_meta_app_id.value },
        { name = "SOCIAL_META_APP_SECRET", value = data.aws_ssm_parameter.social_meta_app_secret.value },
        { name = "SOCIAL_THREADS_APP_ID", value = data.aws_ssm_parameter.social_threads_app_id.value },
        { name = "SOCIAL_THREADS_APP_SECRET", value = data.aws_ssm_parameter.social_threads_app_secret.value },
        { name = "SOCIAL_THREADS_ACCESS_TOKEN", value = data.aws_ssm_parameter.social_threads_access_token.value },
        { name = "SOCIAL_TIKTOK_CLIENT_KEY", value = data.aws_ssm_parameter.social_tiktok_client_key.value },
        { name = "SOCIAL_TIKTOK_CLIENT_SECRET", value = data.aws_ssm_parameter.social_tiktok_client_secret.value },
        { name = "SOCIAL_PINTEREST_APP_ID", value = data.aws_ssm_parameter.social_pinterest_app_id.value },
        { name = "SOCIAL_PINTEREST_APP_SECRET", value = data.aws_ssm_parameter.social_pinterest_app_secret.value },
        { name = "SOCIAL_GITHUB_WEBHOOK_SECRET", value = data.aws_ssm_parameter.social_github_webhook_secret.value },
        { name = "AUTH_GITHUB_OAUTH_CLIENT_ID", value = aws_ssm_parameter.auth_github_oauth_client_id.value },
        { name = "AUTH_GITHUB_OAUTH_CLIENT_SECRET", value = aws_ssm_parameter.auth_github_oauth_client_secret.value },

        # Media storage (bucket + IAM user + config all owned by this stack)
        { name = "STORAGE_TYPE", value = data.aws_ssm_parameter.storage_type.value },
        { name = "STORAGE_S3_BUCKET", value = aws_ssm_parameter.s3_bucket.value },
        { name = "STORAGE_S3_REGION", value = aws_ssm_parameter.s3_region.value },
        { name = "STORAGE_S3_ACCESS_KEY_ID", value = aws_ssm_parameter.s3_access_key_id.value },
        { name = "STORAGE_S3_SECRET_ACCESS_KEY", value = aws_ssm_parameter.s3_secret_access_key.value },
        { name = "STORAGE_PUBLIC_URL_BASE", value = aws_ssm_parameter.storage_public_url_base.value },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs_log_group.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = var.container_name_api
        }
      }
    }
  ])
}
