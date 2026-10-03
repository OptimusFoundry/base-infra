# Create an ECS Cluster
resource "aws_ecs_cluster" "ecs_cluster" {
  name = "ecs-cluster" # Name of the ECS cluster

  # Off by default (it bills per metric). Turn on for a day while re-sizing tasks:
  # polymarket-bot `python -m sports.ops.sizing measure` reads ECS/ContainerInsights.
  setting {
    name  = "containerInsights"
    value = var.ecs_container_insights ? "enabled" : "disabled"
  }
}

# Fargate capacity for on-demand jobs that must not take the shared host's memory (polymarket-bot CH-011: the
# pmbot-research-fargate family, started with a FARGATE_SPOT or FARGATE capacity-provider strategy).
#
# AUTHORITATIVE for the cluster's capacity providers and its default strategy. Before this resource the cluster had
# neither (2026-10-02: describe-clusters capacityProviders [] and defaultCapacityProviderStrategy []): the EC2 host
# joins through ECS_CLUSTER in the launch template below, not through an Auto Scaling group capacity provider, and
# every service and schedule of every product sets launch_type = "EC2". So the list is exactly the two Fargate
# providers and there is deliberately NO default_capacity_provider_strategy: a run-task that names neither a launch
# type nor a strategy keeps landing on the EC2 host, as before. A future EC2 capacity provider is added to THIS list;
# a second aws_ecs_cluster_capacity_providers resource would fight this one.
resource "aws_ecs_cluster_capacity_providers" "ecs_cluster" {
  cluster_name       = aws_ecs_cluster.ecs_cluster.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

# IAM Role for ECS Service
# This role allows ECS to assume the role and interact with other AWS services.
resource "aws_iam_role" "ecs_service_role" {
  name = "ecsServiceRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ecs.amazonaws.com" # ECS Service
        },
        Action = ["sts:AssumeRole"],
      },
    ],
  })
}

# IAM Policy for ECS Service Role
# Attach a policy that grants permissions for ECS Service to interact with other AWS services.
resource "aws_iam_role_policy_attachment" "ecs_service_role_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceRole" # Policy for ECS Service
  role       = aws_iam_role.ecs_service_role.name                                   # Attach to ECS service role
}

# IAM Role for EC2 Instances
# This role allows EC2 instances to assume the role and interact with ECS.
resource "aws_iam_role" "ec2_role" {
  name = "ec2Role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com" # EC2 Service
        },
        Action = ["sts:AssumeRole"],
      },
    ],
  })
}

# IAM Instance Profile for EC2 Instances
# Connects an instance profile to the EC2 role, used to manage permissions for ECS EC2 instances.
resource "aws_iam_instance_profile" "ecs_instance_profile" {
  name = "ecs_instance_profile"
  role = aws_iam_role.ec2_role.name # Reference the EC2 role
}

# IAM Policy for EC2 Role
# Attach a policy that allows EC2 instances to interact with ECS.
resource "aws_iam_role_policy_attachment" "ecs_policy_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
  role       = aws_iam_role.ec2_role.name # Attach to EC2 role
}

# IAM Policy for SSM
resource "aws_iam_role_policy_attachment" "ssm_policy_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.ec2_role.name # Attach to EC2 role
}

# Latest ECS-optimized Amazon Linux 2023 AMI for arm64 (Graviton). AWS publishes
# the recommended image id via SSM, so we resolve it at apply time instead of
# hardcoding — guarantees we never accidentally pin an x86 AMI on an arm host.
data "aws_ssm_parameter" "ecs_optimized_arm64_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/arm64/recommended/image_id"
}

# Launch template for the single ECS host every product runs on, pmbot included.
#
# t4g.2xlarge (8 vCPU, 32 GB): the web products reserve ~1,900 CPU units / 4.6 GB
# and pmbot ~3,300 / 7.9 GB, with headroom for rolling API deploys. Changing the
# type updates the template in place; the running instance only picks it up when
# it is replaced (no instance_refresh), so a resize is: apply, then terminate the
# instance and let the ASG launch a new one — a few minutes of downtime for every
# product.
resource "aws_launch_template" "ecs_host" {
  name_prefix            = "ecs-host-"
  image_id               = data.aws_ssm_parameter.ecs_optimized_arm64_ami.value
  instance_type          = var.ecs_instance_type
  vpc_security_group_ids = [aws_security_group.web_dmz.id]
  update_default_version = true

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance_profile.name
  }

  # Pinned so an account-default change cannot silently drop the host to the
  # "standard" 40%-per-vCPU baseline under pmbot's CPU-bound predictor runs.
  credit_specification {
    cpu_credits = "unlimited"
  }

  # Matches what the previous launch configuration produced (IMDSv2, hop limit 2).
  # Hop limit 2 lets bridge-mode containers reach the instance role; dropping it to
  # 1 is a separate change, after confirming no app relies on instance credentials.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  # ECS_ENABLE_TASK_IAM_ROLE: pmbot's bridge-mode tasks run with task roles.
  # ECS_RESERVED_MEMORY: keeps 512 MiB for the OS and agent out of scheduling.
  user_data = base64encode(<<-EOF
    #!/bin/bash
    sudo yum install -y amazon-ssm-agent
    sudo systemctl start amazon-ssm-agent
    sudo systemctl enable amazon-ssm-agent

    sudo dnf install -y ec2-instance-connect
    cat >> /etc/ecs/ecs.config <<'ECSCONFIG'
    ECS_CLUSTER=${aws_ecs_cluster.ecs_cluster.name}
    ECS_ENABLE_TASK_IAM_ROLE=true
    ECS_RESERVED_MEMORY=512
    ECSCONFIG
  EOF
  )

  # Docker images and pmbot's per-family data volumes live on the root volume.
  block_device_mappings {
    device_name = data.aws_ami.ecs_optimized_arm64.root_device_name

    ebs {
      volume_size           = var.ecs_root_volume_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_ami" "ecs_optimized_arm64" {
  owners = ["amazon"]

  filter {
    name   = "image-id"
    values = [data.aws_ssm_parameter.ecs_optimized_arm64_ami.value]
  }
}

# AutoScaling Group
# AutoScaling group to manage ECS instances.
resource "aws_autoscaling_group" "ecs_autoscaling" {
  vpc_zone_identifier = [aws_subnet.public_subnet_a.id, aws_subnet.public_subnet_b.id] # Subnets for the ASG
  min_size            = 1                                                              # Minimum number of instances
  max_size            = 1                                                              # Maximum number of instances
  desired_capacity    = 1                                                              # Desired number of instances

  launch_template {
    id      = aws_launch_template.ecs_host.id
    version = aws_launch_template.ecs_host.latest_version
  }

  tag {
    key                 = "Name"
    value               = "ECS AutoScaling Group"
    propagate_at_launch = true
  }
}

# IAM Role for ECS Task Execution
# This role allows ECS tasks to assume roles for executing containers.
resource "aws_iam_role" "ecs_task_role" {
  name = "ecsTaskRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = ["ecs-tasks.amazonaws.com"] # ECS Tasks
      },
      Action = ["sts:AssumeRole"],
    }],
  })
}

# IAM Policy for ECS Task Execution
# This policy grants ECS tasks permissions to interact with CloudWatch Logs and other services.
resource "aws_iam_role_policy_attachment" "ecs_task_policy_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" # Policy for ECS tasks
  role       = aws_iam_role.ecs_task_role.name                                         # Attach to ECS task role
}
