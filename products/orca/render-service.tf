# render-service: Remotion + Fastify worker that renders slideshow video and
# uploads it to the media bucket. Driven entirely over Kafka — base-server's
# render stage publishes to the request topic, this consumes it and publishes
# the outcome back on the result topic.
#
# Nothing on the ALB points here. The HTTP port exists only for the manual
# POST /v1/render route and the container health check.

locals {
  # Both services default to these strings internally, but each has its own
  # variable name for them (see the comment in ecs-service.tf). Pinning both
  # sides to one local is what guarantees they cannot drift apart.
  render_request_topic = "content-job.render.requested"
  render_result_topic  = "content-job.render.results"
}

resource "aws_cloudwatch_log_group" "render_service" {
  name              = "/${var.product}/render-service"
  retention_in_days = module.product.log_retention_days
}

resource "aws_ecs_task_definition" "render_service" {
  family             = "${var.product}-render-service"
  execution_role_arn = data.terraform_remote_state.platform.outputs.ecs_task_role_arn
  network_mode       = "bridge"

  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([
    {
      name  = var.render_service_container_name
      image = "${aws_ecr_repository.render_service.repository_url}:${var.render_service_image_tag}"
      cpu   = var.render_service_cpu

      # Soft reservation only — deliberately no `memory` hard cap. Chromium's
      # RSS spikes while compositing; a hard cap it briefly crosses kills the
      # task mid-render, which loses the job rather than merely slowing it.
      memoryReservation = var.render_service_memory_reservation
      essential         = true

      portMappings = [
        { containerPort = 3000, hostPort = 0 }
      ]

      healthCheck = {
        command  = ["CMD-SHELL", "node -e \"require('http').get('http://127.0.0.1:3000/health',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))\""]
        interval = 30
        timeout  = 5
        retries  = 3
        # Remotion bundles the composition on boot, which is slow and CPU-bound
        # on a shared t4g. A short grace period would restart-loop the task
        # before it ever finishes starting.
        startPeriod = 120
      }

      environment = [
        { name = "NODE_ENV", value = var.environment },
        { name = "PORT", value = "3000" },

        { name = "KAFKA_BROKERS", value = data.terraform_remote_state.platform.outputs.kafka_bootstrap_servers },
        { name = "KAFKA_CONSUMER_GROUP", value = "${var.product}.render-service" },
        { name = "RENDER_REQUEST_TOPIC", value = local.render_request_topic },
        { name = "RENDER_RESULT_TOPIC", value = local.render_result_topic },

        { name = "S3_BUCKET", value = aws_s3_bucket.media.id },
        { name = "S3_REGION", value = var.aws_region },
        { name = "MEDIA_PUBLIC_URL_BASE", value = aws_ssm_parameter.storage_public_url_base.value },

        # render-service builds its S3 client with no explicit credentials, so
        # it resolves them through the AWS SDK default chain — which reads the
        # SDK-standard names below. base-server passes the SAME key material
        # under S3_ACCESS_KEY_ID/S3_SECRET_ACCESS_KEY. The duplication is the
        # two services' differing conventions, not two different identities.
        { name = "AWS_ACCESS_KEY_ID", value = aws_iam_access_key.media.id },
        { name = "AWS_SECRET_ACCESS_KEY", value = aws_iam_access_key.media.secret },
        { name = "AWS_REGION", value = var.aws_region },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.render_service.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = var.render_service_container_name
        }
      }
    }
  ])
}

resource "aws_ecs_service" "render_service" {
  name                 = var.render_service_name
  cluster              = data.terraform_remote_state.platform.outputs.ecs_cluster_id
  desired_count        = var.render_service_desired_count
  launch_type          = "EC2"
  task_definition      = aws_ecs_task_definition.render_service.arn
  force_new_deployment = true
}
