# One-shot Flyway migrator, as in aitravel and agentworks. No ECS service: CI
# (orca-server.yml) starts it with `aws ecs run-task` between the image push and
# the API deploy, waits for it to stop, and fails the deploy unless the
# container named `migrator` exits 0. The repository, family and log group
# reach CI through the manifest (manifest.tf), not hardcoded names.
#
# The image's entrypoint reads DB_HOST, DB_PORT, DB_NAME, DB_USERNAME and
# DB_PASSWORD — the same values the API task gets (ecs-service.tf), repeated
# here rather than shared so the API task definition stays untouched.

resource "aws_ecr_repository" "migrator" {
  name                 = var.migrator_ecr_repository_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# CI pushes on every merge to main; keep the last 10 images.
resource "aws_ecr_lifecycle_policy" "migrator" {
  repository = aws_ecr_repository.migrator.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire all but the 10 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

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

      environment = [
        { name = "DB_HOST", value = data.aws_ssm_parameter.rds_host.value },
        { name = "DB_PORT", value = data.aws_ssm_parameter.rds_port.value },
        { name = "DB_NAME", value = aws_ssm_parameter.db_name.value },
        { name = "DB_USERNAME", value = data.aws_ssm_parameter.platform_db_username.value },
        { name = "DB_PASSWORD", value = data.aws_ssm_parameter.platform_db_password.value },
      ]

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
