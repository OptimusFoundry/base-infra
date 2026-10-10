# One-shot Flyway migrator. No ECS service: CI (the agentworks deploy workflow,
# not yet written — README.md "Deploys") starts it with `aws ecs run-task`
# between the image push and the API deploy, waits for it to stop, and fails
# the deploy unless the container named `migrator` exits 0. The family and log
# group reach CI through the manifest (manifest.tf), not hardcoded names.
#
# The image's entrypoint reads exactly DB_HOST, DB_PORT, DB_NAME, DB_USERNAME
# and DB_PASSWORD — the same values the API gets (local.db_environment).

resource "aws_ecs_task_definition" "migrator" {
  family             = "${var.product}-migrator"
  execution_role_arn = data.terraform_remote_state.platform.outputs.ecs_task_role_arn
  network_mode       = "bridge"

  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([
    {
      # CI's exit-code check selects on this name — do not rename it alone.
      name              = "migrator"
      image             = "${aws_ecr_repository.migrator.repository_url}:${var.migrator_image_tag}"
      cpu               = var.migrator_container_cpu
      memoryReservation = var.migrator_container_memory_reservation
      memory            = var.migrator_container_memory
      essential         = true

      environment = local.db_environment

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.api.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "migrator"
        }
      }
    }
  ])
}
