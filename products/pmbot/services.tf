locals {
  # Same string as aws_ecr_repository.pmbot.repository_url, built from known values so the
  # review plan can show the container definitions before the repository exists.
  registry   = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
  image_repo = "${local.registry}/${aws_ecr_repository.pmbot.name}"

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
    LIVE_TRADING             = "0"
    LIVE_LEAGUES             = "NBA,NHL"
    MAKER_PREDICTIONS_SOURCE = "published" # CHORE-014 (2026-10-01): maker reads the predictor's published predictions
  }

  # The size of every family (polymarket-bot EP-032, sports/ops/sizing.py SIZES; `python -m sports.ops.sizing
  # check-tf services.tf` exits 1 on drift and ci/test_services_sizes.py pins the same table). MiB and CPU units:
  # memory_reservation is what the ECS scheduler counts, memory is the container's hard cap (exceeding it kills
  # that container alone). maker-live (EP-033) has no task definition yet: it is listed so the host headroom
  # counts it. One family per line, in this exact form: sizing.py parses it.
  task_sizes = {
    "maker-live"     = { cpu = 512, memory_reservation = 1024, memory = 2048 }
    "maker-paper"    = { cpu = 512, memory_reservation = 1024, memory = 2048 }
    "predictor"      = { cpu = 1024, memory_reservation = 2048, memory = 4096 }
    "recorder"       = { cpu = 256, memory_reservation = 512, memory = 1024 }
    "ingame-capture" = { cpu = 128, memory_reservation = 960, memory = 1472 }
    "xvenue-poller"  = { cpu = 128, memory_reservation = 256, memory = 512 }
    "rewards-poll"   = { cpu = 128, memory_reservation = 320, memory = 512 }
    "daily-ingest"   = { cpu = 512, memory_reservation = 1536, memory = 4096 }
  }

  # The research job slot (EP-034): no task definition yet. It has no memoryReservation, so ECS places it only
  # into memory nothing has reserved (a container without a reservation counts its hard cap, 4096 MiB), and its
  # CPU weight (512) is the lowest of the CPU-bound tasks (the predictor has 1024).
  research_slot = { cpu = 512, memory = 4096 }

  # The five long-running services. Commands mirror sports/ops/services.py SERVICES (T15 diffs
  # them). `size` is the family's row of local.task_sizes. SPORTS_CACHE_PRUNE (EP-032,
  # sports.core.cache_prune) lets the family's own drainer delete S3-verified local files older than N days
  # under one prefix of its private /data/<family>; only write-once prefixes are listed.
  services = {
    recorder = {
      command   = ["python", "-m", "sports.recorder.runner"]
      size      = local.task_sizes["recorder"]
      extra_env = { SPORTS_CACHE_PRUNE = "recorder/=7" }
    }
    maker-paper = {
      command   = ["python", "-m", "sports.live.run", "loop"]
      size      = local.task_sizes["maker-paper"]
      extra_env = merge(local.maker_env, { SPORTS_CACHE_PRUNE = "predictions/=3" })
    }
    ingame-capture = {
      command   = ["python", "-m", "sports.collectors.ingame_capture"]
      size      = local.task_sizes["ingame-capture"]
      extra_env = { SPORTS_CACHE_PRUNE = "collectors/=7" }
    }
    xvenue-poller = {
      command   = ["python", "-m", "sports.collectors.xvenue_poller"]
      size      = local.task_sizes["xvenue-poller"]
      extra_env = { SPORTS_CACHE_PRUNE = "collectors/=7" }
    }
    rewards-poll = {
      command   = ["python", "-m", "sports.collectors.rewards_poll"]
      size      = local.task_sizes["rewards-poll"]
      extra_env = { SPORTS_CACHE_PRUNE = "collectors/=7" }
    }
  }

  # The scheduled task (sports/ops/services.py SCHEDULED). Run by EventBridge Scheduler, not a service.
  # DAILY_INGEST_REQUIRE_DRAINED=1 (EP-032): an unfinished post-ingest upload drain fails the verdict, so the run
  # never leaves markers behind on its private /data/daily-ingest. No SPORTS_CACHE_PRUNE: its raw caches are reused
  # daily and it has no background drainer.
  daily_ingest = {
    command   = ["python", "-m", "sports.ops.daily_ingest"]
    size      = local.task_sizes["daily-ingest"]
    extra_env = { DAILY_INGEST_REQUIRE_DRAINED = "1" }
  }

  # The predictor (EP-030, sports/ops/services.py SCHEDULED): publishes predictions/<league>/... every
  # 15 minutes. Run by EventBridge Scheduler like daily-ingest. Spec section 6 size (2048/4096/1024) since the
  # t4g.xlarge (EP-032). PREDICTOR_LEAGUES is the CLI's default league list. PMBOT_GIT_SHA (its model_version) is
  # injected by pmbot-deploy, never here: a Terraform-registered revision runs the bootstrap image.
  predictor = {
    command   = ["python", "-m", "sports.models.predictor.run", "publish"]
    size      = local.task_sizes["predictor"]
    extra_env = { PREDICTOR_LEAGUES = "NBA,NHL", SPORTS_CACHE_PRUNE = "predictions/=3" }
  }

  all_tasks = merge(local.services, {
    "daily-ingest" = local.daily_ingest
    "predictor"    = local.predictor
  })

  # The plane each task runs as (EP-031): its task role is aws_iam_role.plane[<plane>] (iam.tf local.planes) and
  # its S3 upload queue is SPORTS_S3_QUEUE=<plane> (sports.core.s3sync). The role and the queue change in the
  # same revision on purpose: a plane role cannot upload another plane's files, so a drainer that shared the
  # root queue would be denied on them. Keys == local.all_tasks (a missing key fails the plan) ==
  # sports/ops/services.py SERVICES | SCHEDULED; polymarket-bot sports/ops/images.py FAMILY_TARGET is the
  # image-side twin of this map.
  family_plane = {
    recorder         = "collect"
    "ingame-capture" = "collect"
    "xvenue-poller"  = "collect"
    "rewards-poll"   = "collect"
    "daily-ingest"   = "model"
    predictor        = "model"
    "maker-paper"    = "paper"
  }

  # The image target each task runs (EP-031): CI pushes <sha>-collect, <sha>-model, <sha>-trade and
  # <sha>-research (plus <sha> = the research image). A family's Terraform-registered revision runs
  # ${var.image_tag}-<target>, and pmbot-deploy keeps that target when it swaps the sha (ecs_deploy.py
  # target_tag). Twin of polymarket-bot sports/ops/images.py FAMILY_TARGET (its test pins that map to
  # ecs_deploy.py); ci/test_services_maps.py pins this one to family_plane.
  family_target = {
    recorder         = "collect"
    "ingame-capture" = "collect"
    "xvenue-poller"  = "collect"
    "rewards-poll"   = "collect"
    "daily-ingest"   = "model"
    predictor        = "model"
    "maker-paper"    = "trade"
  }

  # One container per task definition; the container is named after the service.
  container_definitions = {
    for name, task in local.all_tasks : name => [{
      name              = name
      image             = "${local.image_repo}:${var.image_tag}-${local.family_target[name]}"
      command           = task.command
      essential         = true
      cpu               = task.size.cpu
      memoryReservation = task.size.memory_reservation
      memory            = task.size.memory
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
        for key, value in merge(local.common_env, { SPORTS_S3_QUEUE = local.family_plane[name] }, task.extra_env) : { name = key, value = value }
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
  task_role_arn            = aws_iam_role.plane[local.family_plane[each.key]].arn
  container_definitions    = jsonencode(local.container_definitions[each.key])

  # Hosts are Graviton (t4g); the image is built linux/arm64 in CI.
  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  # /data/<family> is a host directory per task (user data creates it, owned by uid 10001, EP-032): it outlives a
  # task restart, so a redeploy does not lose buffered rows or the paper journal. The container path stays /data
  # (SPORTS_DATA_ROOT=/data), so no in-container path changes. S3 is the only channel between services.
  volume {
    name      = "data"
    host_path = "/data/${each.key}"
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
  task_role_arn            = aws_iam_role.plane[local.family_plane["daily-ingest"]].arn
  container_definitions    = jsonencode(local.container_definitions["daily-ingest"])

  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  volume {
    name      = "data"
    host_path = "/data/daily-ingest"
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
  task_role_arn            = aws_iam_role.plane[local.family_plane["predictor"]].arn
  container_definitions    = jsonencode(local.container_definitions["predictor"])

  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  volume {
    name      = "data"
    host_path = "/data/predictor"
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
