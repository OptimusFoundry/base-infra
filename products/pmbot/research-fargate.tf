# Parallel research jobs on Fargate Spot (polymarket-bot CH-011; runbook docs/runbooks/research-jobs.md there).
#
# The EC2 family pmbot-research (research.tf) stays as the launcher's `--on-host` fallback. This family runs every job
# as its own Fargate task: its own 50 GiB disk at /data (no Docker volume, nothing shared between jobs; the image's
# /data is owned by the container user), its own upload queue, and awsvpc networking in the platform VPC's public
# subnets with a public IP (the VPC has no NAT) behind an egress-only security group. polymarket-bot's
# `python -m sports.research.run` starts it with a FARGATE_SPOT (default) or FARGATE (`--fargate`) capacity-provider
# strategy (platform/ecs.tf associates both with ecs-cluster) and reads the subnets and the security group from the
# SSM parameter below. Like pmbot-research it is not in local.services / local.all_tasks / local.family_plane /
# local.family_target: no service, no schedule, no not-running alarm. polymarket-bot's pmbot-deploy registers the
# revisions that run (:<sha>-research); this revision carries the bootstrap image, which has no
# sports.research.jobs entry point (its command only says so).

locals {
  # 1 vCPU / 8 GiB, the Graviton Fargate maximum memory at 1 vCPU: twice the EC2 slot's 4096 MiB hard cap that every
  # ECS dev job so far ran under (polymarket-bot CH-011 plan, ruling 6). 50 GiB of disk: staged panels, the
  # price/tape caches and one job's outputs (20 GiB is Fargate's free default).
  research_fargate_size = { cpu = 1024, memory = 8192, ephemeral_gib = 50 }

  research_fargate_container = [{
    name        = "research"
    image       = "${local.image_repo}:${var.image_tag}-research"
    command     = ["python", "-c", "raise SystemExit('pmbot-research-fargate: run it through python -m sports.research.run (command override)')"]
    essential   = true
    stopTimeout = 120

    linuxParameters = {
      initProcessEnabled = true
    }

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

# No ingress at all. Egress HTTPS only: ECR and its S3 layers, the data bucket, CloudWatch Logs and the free data
# sources (polymarket-bot's fetchers are https only). DNS goes to the VPC resolver, which security groups do not
# filter. The public subnets' network ACL already allows 443 out and the ephemeral ports back in
# (platform/networking.tf).
resource "aws_security_group" "research_fargate" {
  name        = "pmbot-research-fargate"
  description = "pmbot research jobs on Fargate: no inbound, HTTPS out"
  vpc_id      = data.terraform_remote_state.platform.outputs.vpc_id

  egress {
    description = "HTTPS out"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_task_definition" "research_fargate" {
  family                   = "pmbot-research-fargate"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(local.research_fargate_size.cpu)
  memory                   = tostring(local.research_fargate_size.memory)
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.plane["research"].arn
  container_definitions    = jsonencode(local.research_fargate_container)

  # Graviton, like the shared host; images are built linux/arm64 in CI. The public subnets are in use1-az2 and
  # use1-az4 (use1-az3 has no Fargate ARM64).
  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  ephemeral_storage {
    size_in_gib = local.research_fargate_size.ephemeral_gib
  }
}

# What the launcher passes as --network-configuration (it adds assignPublicIp = ENABLED). Read by
# pmbot-github-research-run (github.tf) and the owner's Mac. A plain String: IDs, no secret.
resource "aws_ssm_parameter" "research_fargate_network" {
  name        = "/${local.name}/research-fargate/network"
  description = "pmbot-research-fargate awsvpc network (polymarket-bot sports.research.run)"
  type        = "String"
  value = jsonencode({
    subnets        = data.terraform_remote_state.platform.outputs.public_subnet_ids
    securityGroups = [aws_security_group.research_fargate.id]
  })
}
