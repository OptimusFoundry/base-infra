# On-demand research jobs (polymarket-bot EP-034, spec section 7; runbook docs/runbooks/research-jobs.md there).
#
# A task definition and its log group, nothing else: no service, no schedule. polymarket-bot's
# `python -m sports.research.run <experiment>` (or its pmbot-research workflow, role in github.tf) calls
# `ecs run-task --launch-type EC2` on this family in the shared cluster, so a job is placed only into memory no
# task on the host has reserved, or refused at once (RESOURCE:MEMORY), never queued. It is not in local.services /
# local.all_tasks / local.family_plane / local.family_target on purpose: those maps drive the services, the
# not-running alarms, the per-task log groups and metric filters. polymarket-bot's pmbot-deploy registers a new
# revision per deploy with the :<sha>-research image and PMBOT_GIT_SHA; this revision carries the bootstrap image,
# which has no sports.research.jobs entry point (its command only says so).

locals {
  # The job's whole environment: the common contract with the writes forced on (the research role may PutObject its
  # prefixes), its own upload queue (a plane role cannot upload another plane's files) and the durable S3 ledger
  # (research/harness/ledger_s3.py; any S3 doubt makes the vault refuse). No LIVE_*, no POLYMARKET_*, no secret.
  research_env = merge(local.common_env, {
    SPORTS_S3       = "rw"
    SPORTS_S3_QUEUE = "research"
    SPORTS_LEDGER   = "s3"
  })

  # No memoryReservation: ECS then counts the hard cap (4096 MiB) when it places the task, so a job fits only into
  # memory no task of any product on the shared host has reserved. The cap is a cgroup limit: a runaway job is
  # OOM-killed alone. cpu is a relative weight, not a cap.
  research_container = [{
    name        = "research"
    image       = "${local.image_repo}:${var.image_tag}-research"
    command     = ["python", "-c", "raise SystemExit('pmbot-research: run it through python -m sports.research.run (command override)')"]
    essential   = true
    cpu         = local.research_slot.cpu
    memory      = local.research_slot.memory
    stopTimeout = 120

    linuxParameters = {
      initProcessEnabled = true
    }

    mountPoints = [{
      sourceVolume  = "pmbot-research"
      containerPath = "/data"
      readOnly      = false
    }]

    environment = [for key, value in local.research_env : { name = key, value = value }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.research.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "research"
      }
    }
  }]
}

# The /ecs/pmbot/<name> convention. The launcher reads the stream research/research/<task id>
# (prefix/container/task id); the workflow role in github.tf may read this group and nothing else.
resource "aws_cloudwatch_log_group" "research" {
  name              = "/ecs/pmbot/research"
  retention_in_days = 30
}

resource "aws_ecs_task_definition" "research" {
  family                   = "pmbot-research"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.plane["research"].arn
  container_definitions    = jsonencode(local.research_container)

  # Hosts are Graviton (t4g); images are built linux/arm64 in CI.
  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  # The job's own volume, like every family's (services.tf): Docker creates it at the first job and seeds it from
  # the image's /data (owned by the container user), it outlives each job (staged panels, the ledger cache, the
  # upload queue) but not the host, and no other family mounts it. Two concurrent jobs would share it: the
  # polymarket-bot runbook runs one at a time.
  volume {
    name = "pmbot-research"

    docker_volume_configuration {
      scope         = "shared"
      autoprovision = true
      driver        = "local"
    }
  }
}
