locals {
  # Same string as aws_ecr_repository.pmbot.repository_url, built from known values so a plan
  # shows the container definitions in full.
  registry   = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
  image_repo = "${local.registry}/${aws_ecr_repository.pmbot.name}"

  # Environment shared by every task. No credential, no POLYMARKET_*, no LIVE_ENABLE_*: the AWS
  # SDK gets the task role through the ECS agent.
  common_env = {
    SPORTS_DATA_ROOT   = "/data"
    SPORTS_S3          = var.sports_s3_mode
    SPORTS_S3_BUCKET   = var.data_bucket
    AWS_REGION         = var.aws_region
    AWS_DEFAULT_REGION = var.aws_region
    PYTHONUNBUFFERED   = "1"
  }

  # Paper only, forced here and nowhere configurable.
  maker_env = {
    LIVE_TRADING             = "0"
    LIVE_LEAGUES             = "NBA,NHL"
    MAKER_PREDICTIONS_SOURCE = "published" # the maker reads the predictor's published predictions
  }

  # The size of every family, in CPU units and MiB. memory_reservation is what the ECS scheduler
  # counts; memory is the container's hard cap (exceeding it kills that container alone). maker-live
  # has no task definition yet; it is listed so host headroom counts it. Must equal polymarket-bot
  # sports/ops/sizing.py SIZES, whose `check-tf` command parses this block: keep one family per line.
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

  # The research job's size (research.tf, polymarket-bot EP-034). No memoryReservation, so ECS counts the
  # hard cap at placement and a job only fits into memory nothing on the shared host has reserved.
  research_slot = { cpu = 512, memory = 4096 }

  # The five long-running services; commands mirror polymarket-bot sports/ops/services.py SERVICES.
  # SPORTS_CACHE_PRUNE lets a family delete S3-verified local files older than N days under one
  # write-once prefix of its own data volume.
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

  # Scheduled tasks (sports/ops/services.py SCHEDULED), run by EventBridge Scheduler (schedule.tf).
  # DAILY_INGEST_REQUIRE_DRAINED=1: an unfinished upload drain fails the run's verdict.
  daily_ingest = {
    command   = ["python", "-m", "sports.ops.daily_ingest"]
    size      = local.task_sizes["daily-ingest"]
    extra_env = { DAILY_INGEST_REQUIRE_DRAINED = "1" }
  }

  # Publishes predictions/<league>/... every 15 minutes. PMBOT_GIT_SHA (its model_version) is
  # injected by pmbot-deploy, never here.
  predictor = {
    command   = ["python", "-m", "sports.models.predictor.run", "publish"]
    size      = local.task_sizes["predictor"]
    extra_env = { PREDICTOR_LEAGUES = "NBA,NHL", SPORTS_CACHE_PRUNE = "predictions/=3" }
  }

  all_tasks = merge(local.services, {
    "daily-ingest" = local.daily_ingest
    "predictor"    = local.predictor
  })

  # The plane each task runs as: task role aws_iam_role.plane[<plane>] and upload queue
  # SPORTS_S3_QUEUE=<plane>. They change together: a plane role cannot upload another plane's files.
  family_plane = {
    recorder         = "collect"
    "ingame-capture" = "collect"
    "xvenue-poller"  = "collect"
    "rewards-poll"   = "collect"
    "daily-ingest"   = "model"
    predictor        = "model"
    "maker-paper"    = "paper"
  }

  # The image target each task runs (<sha>-<target>). Must equal polymarket-bot
  # sports/ops/images.py FAMILY_TARGET; pmbot-deploy keeps the target when it swaps the sha.
  family_target = {
    recorder         = "collect"
    "ingame-capture" = "collect"
    "xvenue-poller"  = "collect"
    "rewards-poll"   = "collect"
    "daily-ingest"   = "model"
    predictor        = "model"
    "maker-paper"    = "trade"
  }

  # One container per task definition, named after the family. /data is the family's own Docker
  # volume (pmbot-<family>), so no two families share a data directory.
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
        sourceVolume  = "pmbot-${name}"
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
  for_each = local.all_tasks

  family                   = "pmbot-${each.key}"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.plane[local.family_plane[each.key]].arn
  container_definitions    = jsonencode(local.container_definitions[each.key])

  # Hosts are Graviton (t4g); images are built linux/arm64 in CI.
  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  # A shared-scope Docker volume outlives the task, so a restart or redeploy keeps buffered rows and
  # the paper journal; it does not outlive the host (the data is in S3, and the maker restores its
  # journal on start). Docker seeds a new volume from the image's /data, which is owned by the
  # container user, so the host needs no per-product setup.
  volume {
    name = "pmbot-${each.key}"

    docker_volume_configuration {
      scope         = "shared"
      autoprovision = true
      driver        = "local"
    }
  }
}

moved {
  from = aws_ecs_task_definition.daily_ingest
  to   = aws_ecs_task_definition.svc["daily-ingest"]
}

moved {
  from = aws_ecs_task_definition.predictor
  to   = aws_ecs_task_definition.svc["predictor"]
}

# Stop-then-start deploys: the old task gets SIGTERM and up to 120 s to flush before the new one
# starts, so two recorders, or two makers on one data volume, never run at once.
resource "aws_ecs_service" "svc" {
  for_each = local.services

  name                 = "pmbot-${each.key}"
  cluster              = local.cluster_id
  launch_type          = "EC2"
  task_definition      = aws_ecs_task_definition.svc[each.key].arn
  desired_count        = 1
  force_new_deployment = true

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  enable_execute_command             = true

  # desired_count: a manual kill switch (`--desired-count 0`) survives an apply.
  # task_definition: polymarket-bot's pmbot-deploy owns the running revision, so an apply never
  # moves a service back to the bootstrap-image revision.
  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }
}
