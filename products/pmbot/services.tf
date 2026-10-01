locals {
  # Same string as aws_ecr_repository.pmbot.repository_url, built from known values so the
  # review plan can show the container definitions before the repository exists.
  registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
  image    = "${local.registry}/${aws_ecr_repository.pmbot.name}:${var.image_tag}"

  # Environment contract shared by every task (head: Shared interfaces). No credential, no
  # POLYMARKET_*, no LIVE_ENABLE_*: the AWS SDK gets the task role through the ECS agent.
  common_env = {
    SPORTS_DATA_ROOT   = "/data"
    SPORTS_S3          = var.sports_s3_mode
    SPORTS_S3_BUCKET   = var.data_bucket
    AWS_REGION         = var.aws_region
    AWS_DEFAULT_REGION = var.aws_region
    PYTHONUNBUFFERED   = "1"
  }

  # Paper only, forced here and nowhere configurable (sports-live-rules:L-1).
  maker_env = {
    LIVE_TRADING = "0"
    LIVE_LEAGUES = "NBA,NHL"
  }

  # The five long-running services. Commands mirror sports/ops/services.py SERVICES (T15 diffs
  # them). Sizes are MiB for memory and CPU units; reservation is what the scheduler counts.
  services = {
    recorder = {
      command            = ["python", "-m", "sports.recorder.runner"]
      cpu                = 256
      memory_reservation = 1024
      memory             = 2048
      extra_env          = {}
    }
    maker-paper = {
      command            = ["python", "-m", "sports.live.run", "loop"]
      cpu                = 256
      memory_reservation = 1024
      memory             = 2048
      extra_env          = local.maker_env
    }
    ingame-capture = {
      command            = ["python", "-m", "sports.collectors.ingame_capture"]
      cpu                = 256
      memory_reservation = 512
      memory             = 1024
      extra_env          = {}
    }
    xvenue-poller = {
      command            = ["python", "-m", "sports.collectors.xvenue_poller"]
      cpu                = 128
      memory_reservation = 256
      memory             = 768
      extra_env          = {}
    }
    rewards-poll = {
      command            = ["python", "-m", "sports.collectors.rewards_poll"]
      cpu                = 64
      memory_reservation = 256
      memory             = 512
      extra_env          = {}
    }
  }

  # The scheduled task (sports/ops/services.py SCHEDULED). Run by EventBridge Scheduler, not a service.
  daily_ingest = {
    command            = ["python", "-m", "sports.ops.daily_ingest"]
    cpu                = 512
    memory_reservation = 2048
    memory             = 4096
    extra_env          = {}
  }

  # The predictor (EP-030, sports/ops/services.py SCHEDULED): publishes predictions/<league>/... every
  # 15 minutes. Run by EventBridge Scheduler like daily-ingest. Sized below spec section 6 (2048/4096/1024)
  # because today's t4g.large also runs the five services and the 06:00 ingest (plan OD5); Phase D retunes.
  # PREDICTOR_LEAGUES is the CLI's default league list. PMBOT_GIT_SHA (its model_version) is injected by
  # pmbot-deploy, never here: a Terraform-registered revision runs the bootstrap image.
  predictor = {
    command            = ["python", "-m", "sports.models.predictor.run", "publish"]
    cpu                = 512
    memory_reservation = 1536
    memory             = 3072
    extra_env          = { PREDICTOR_LEAGUES = "NBA,NHL" }
  }

  all_tasks = merge(local.services, {
    "daily-ingest" = local.daily_ingest
    "predictor"    = local.predictor
  })

  # One container per task definition; the container is named after the service.
  container_definitions = {
    for name, task in local.all_tasks : name => [{
      name              = name
      image             = local.image
      command           = task.command
      essential         = true
      cpu               = task.cpu
      memoryReservation = task.memory_reservation
      memory            = task.memory
      stopTimeout       = 120

      linuxParameters = {
        initProcessEnabled = true
      }

      mountPoints = [{
        sourceVolume  = "data"
        containerPath = "/data"
        readOnly      = false
      }]

      environment = [
        for key, value in merge(local.common_env, task.extra_env) : { name = key, value = value }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.svc[name].name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = name
        }
      }
    }]
  }
}

resource "aws_cloudwatch_log_group" "svc" {
  for_each = local.all_tasks

  name              = "/ecs/pmbot/${each.key}"
  retention_in_days = 30
}

resource "aws_ecs_task_definition" "svc" {
  for_each = local.services

  family                   = "pmbot-${each.key}"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions    = jsonencode(local.container_definitions[each.key])

  # Hosts are Graviton (t4g); the image is built linux/arm64 in CI.
  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  # /data is a host directory (user data creates it, owned by uid 10001): it outlives a
  # task restart, so a redeploy does not lose buffered rows or the paper journal.
  volume {
    name      = "data"
    host_path = "/data"
  }

  placement_constraints {
    type       = "memberOf"
    expression = local.placement_expression
  }
}

resource "aws_ecs_task_definition" "daily_ingest" {
  family                   = "pmbot-daily-ingest"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions    = jsonencode(local.container_definitions["daily-ingest"])

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

resource "aws_ecs_task_definition" "predictor" {
  family                   = "pmbot-predictor"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions    = jsonencode(local.container_definitions["predictor"])

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

# Stop-then-start deploys (plan ruling 5): the old task gets SIGTERM and up to 120 s to flush
# before the new one starts, so two recorders, or two makers on one /data, never run at once.
# desired_count is ignored after create: a manual kill switch (`--desired-count 0`, runbook) must survive
# a later apply; scaling back up is an explicit `aws ecs update-service --desired-count 1`.
resource "aws_ecs_service" "svc" {
  for_each = local.services

  name            = "pmbot-${each.key}"
  cluster         = aws_ecs_cluster.pmbot.id
  task_definition = aws_ecs_task_definition.svc[each.key].arn
  desired_count   = 1

  # Dedicated cluster (owner decision D1 = b): placement goes through the pmbot capacity
  # provider, so no launch_type.
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

  # The provider must be attached to the cluster before a service can name it.
  depends_on = [aws_ecs_cluster_capacity_providers.pmbot]

  # desired_count: a manual kill switch (`--desired-count 0`, runbook) survives an apply.
  # task_definition: polymarket-bot's pmbot-deploy workflow owns the running revision (CH-008), so an
  # apply never moves a service back to Terraform's bootstrap-image revision.
  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }
}

output "service_names" {
  value       = { for key, service in aws_ecs_service.svc : key => service.name }
  description = "ECS service names by registry name (cluster: pmbot)"
}

output "log_group_names" {
  value       = { for key, group in aws_cloudwatch_log_group.svc : key => group.name }
  description = "CloudWatch log groups by task name, including daily-ingest and predictor"
}

output "placement_expression" {
  value       = local.placement_expression
  description = "memberOf expression every pmbot task and service carries"
}
