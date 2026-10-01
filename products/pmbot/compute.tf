# Dedicated compute for pmbot: its own ECS cluster ("pmbot", owner decision D1 = b) backed by
# one t4g.large. Nothing here reads or changes the shared ecs-cluster. The instance also
# carries the ECS attribute pmbot=dedicated, which the services may still pin to.

# --- Cluster ---

resource "aws_ecs_cluster" "pmbot" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# --- Instance role: what the ECS agent on the host needs, plus Session Manager ---

resource "aws_iam_role" "instance" {
  name = "pmbot-ecs-instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "instance_ecs" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# The host has no key pair and no inbound rule, so Session Manager is the only way onto it
# (disk, docker, a foreign task on the host). ECS Exec does not need this policy.
resource "aws_iam_role_policy_attachment" "instance_ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "pmbot-ecs-instance"
  role = aws_iam_role.instance.name
}

# --- Network: no inbound at all. The host only dials out (ECS, ECR, S3, Polymarket). ---

resource "aws_security_group" "instance" {
  name        = "pmbot-ecs-instance"
  description = "pmbot ECS host: no inbound, all outbound"
  vpc_id      = local.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "pmbot-ecs-instance"
  }
}

# --- Launch template ---

data "aws_ami" "ecs" {
  owners = ["amazon"]

  filter {
    name   = "image-id"
    values = [data.aws_ssm_parameter.ecs_ami.insecure_value]
  }

  lifecycle {
    postcondition {
      condition     = self.architecture == "arm64"
      error_message = "The ECS AMI must be arm64 for a Graviton (t4g) instance."
    }
  }
}

resource "aws_launch_template" "instance" {
  name_prefix            = "pmbot-ecs-"
  image_id               = data.aws_ami.ecs.id
  instance_type          = var.instance_type
  update_default_version = true

  iam_instance_profile {
    name = aws_iam_instance_profile.instance.name
  }

  # /data (recorder rows, collector files, the paper journal) lives on this volume.
  # The root device name comes from the AMI (/dev/xvda for ECS AL2023), not a literal.
  block_device_mappings {
    device_name = data.aws_ami.ecs.root_device_name

    ebs {
      volume_size           = var.root_volume_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # IMDSv2 only, hop limit 1: a bridge-mode container is one hop behind the host, so it
  # cannot reach the instance role. Tasks use their own task role through the ECS agent.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # No key_name: there is no SSH. The public IPv4 is how the host reaches the internet
  # (platform has an internet gateway and no NAT).
  network_interfaces {
    device_index                = 0
    associate_public_ip_address = true
    delete_on_termination       = true
    security_groups             = [aws_security_group.instance.id]
  }

  user_data = base64encode(<<-EOT
    #!/bin/bash
    set -euo pipefail
    cat >> /etc/ecs/ecs.config <<'ECSCONFIG'
    ECS_CLUSTER=${local.cluster_name}
    ECS_INSTANCE_ATTRIBUTES=${jsonencode({ (local.placement_attribute) = local.placement_value })}
    ECS_ENABLE_TASK_IAM_ROLE=true
    ECS_CONTAINER_STOP_TIMEOUT=120s
    ECSCONFIG
    mkdir -p /data
    chown 10001:10001 /data
    EOT
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      ManagedBy = "terraform"
      Product   = var.product
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      ManagedBy = "terraform"
      Product   = var.product
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# --- Auto Scaling group: exactly one instance ---
#
# The group follows the launch template's latest version but has no instance_refresh: a plan
# never replaces the running instance. Replacement is a deliberate step (runbook: cutover and
# disk replacement), because /data holds rows that may not be in S3 yet.
resource "aws_autoscaling_group" "pmbot" {
  name_prefix         = "pmbot-ecs-"
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = local.public_subnet_ids
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.instance.id
    version = aws_launch_template.instance.latest_version
  }

  tag {
    key                 = "Name"
    value               = "pmbot-ecs"
    propagate_at_launch = true
  }

  # ECS adds this tag itself when the group backs a capacity provider.
  lifecycle {
    ignore_changes = [tag]
  }
}

# --- Capacity provider: ties the ASG to the pmbot cluster only ---
#
# Scaling and termination protection are off: the group is fixed at 1 and a plan must not
# make ECS resize or protect the host.
resource "aws_ecs_capacity_provider" "pmbot" {
  name = "pmbot"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.pmbot.arn
    managed_termination_protection = "DISABLED"

    managed_scaling {
      status = "DISABLED"
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "pmbot" {
  cluster_name       = aws_ecs_cluster.pmbot.name
  capacity_providers = [aws_ecs_capacity_provider.pmbot.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.pmbot.name
    weight            = 1
    base              = 1
  }
}

output "asg_name" {
  value       = aws_autoscaling_group.pmbot.name
  description = "Auto Scaling group of the dedicated pmbot host (terminate its instance to replace it)"
}
