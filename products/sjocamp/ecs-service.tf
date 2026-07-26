resource "aws_cloudwatch_log_group" "api" {
  name              = "/${var.product}/api"
  retention_in_days = module.product.log_retention_days
}

resource "aws_ecs_task_definition" "api" {
  family             = "${var.product}-api"
  execution_role_arn = data.terraform_remote_state.platform.outputs.ecs_task_role_arn
  network_mode       = "bridge"

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

      portMappings = [
        { containerPort = 80, hostPort = 0 }
      ]

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:80/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 2
      }

      environment = [
        { name = "GO_ENV", value = var.environment },
        { name = "GIN_MODE", value = "release" },
        { name = "APP_SERVER_PORT", value = "80" },
        { name = "DB_HOST", value = data.aws_ssm_parameter.rds_host.value },
        { name = "DB_PORT", value = data.aws_ssm_parameter.rds_port.value },
        { name = "DB_USERNAME", value = data.aws_ssm_parameter.platform_db_username.value },
        { name = "DB_PASSWORD", value = data.aws_ssm_parameter.platform_db_password.value },
        { name = "DB_NAME", value = aws_ssm_parameter.db_name.value },
        { name = "AUTH_JWT_SECRET", value = data.aws_ssm_parameter.auth_jwt_secret.value },
        { name = "AUTH_GOOGLE_OAUTH_CLIENT_ID", value = data.aws_ssm_parameter.auth_google_oauth_client_id.value },
        { name = "AUTH_GOOGLE_OAUTH_CLIENT_SECRET", value = data.aws_ssm_parameter.auth_google_oauth_client_secret.value },
        { name = "AUTH_GOOGLE_REDIRECT_URI", value = aws_ssm_parameter.auth_google_redirect_uri.value },
        { name = "APP_WEBAPP_URI", value = aws_ssm_parameter.app_webapp_uri.value },
        { name = "PAYMENTS_STRIPE_SECRET_KEY", value = data.aws_ssm_parameter.platform_stripe_secret_key.value },
        { name = "PAYMENTS_STRIPE_WEBHOOK_SECRET", value = data.aws_ssm_parameter.payments_stripe_webhook_secret.value },
        { name = "PAYMENTS_STRIPE_BILLING_PORTAL_CONFIG_ID", value = aws_ssm_parameter.payments_stripe_billing_portal_config_id.value },
        { name = "EMAIL_RESEND_API_KEY", value = data.aws_ssm_parameter.platform_resend_api_key.value },
        { name = "EMAIL_RESEND_WEBHOOK_SECRET", value = data.aws_ssm_parameter.email_resend_webhook_secret.value },
        { name = "EMAIL_SENDER_ADDRESS", value = data.aws_ssm_parameter.email_sender_address.value },
        { name = "AI_GEMINI_API_KEY", value = data.aws_ssm_parameter.platform_gemini_api_key.value },
        { name = "AI_OPENAI_API_KEY", value = data.aws_ssm_parameter.platform_openai_api_key.value },
        { name = "AUTH_TURNSTILE_SECRET_KEY", value = data.aws_ssm_parameter.platform_turnstile_secret_key.value },
        { name = "APP_PRODUCT_NAME", value = var.product },
        { name = "EVENTS_BROKERS", value = data.terraform_remote_state.platform.outputs.kafka_bootstrap_servers },
        { name = "EVENTS_TOPIC", value = "${var.product}.webhook-events" },
        { name = "EVENTS_CONSUMER_GROUP", value = "${var.product}.webhook-consumers" },
      ]

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
