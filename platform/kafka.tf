# EFS File System for Kafka Data Persistence
resource "aws_efs_file_system" "kafka_data" {
  creation_token = "kafka-data-efs"
  encrypted      = true

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = {
    Name      = "Kafka Data EFS"
    CreatedBy = "Terraform"
    Purpose   = "Kafka persistent storage"
  }
}

# EFS Mount Target in Availability Zone A
resource "aws_efs_mount_target" "kafka_mount_a" {
  file_system_id  = aws_efs_file_system.kafka_data.id
  subnet_id       = aws_subnet.public_subnet_a.id
  security_groups = [aws_security_group.efs_kafka.id]
}

# EFS Mount Target in Availability Zone B
resource "aws_efs_mount_target" "kafka_mount_b" {
  file_system_id  = aws_efs_file_system.kafka_data.id
  subnet_id       = aws_subnet.public_subnet_b.id
  security_groups = [aws_security_group.efs_kafka.id]
}

# Security Group for EFS - Allow NFS access from ECS tasks
resource "aws_security_group" "efs_kafka" {
  name        = "efs-kafka-sg"
  description = "Security group for Kafka EFS mount targets"
  vpc_id      = aws_vpc.base_vpc.id

  ingress {
    description     = "NFS from ECS tasks"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.web_dmz.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "EFS Kafka Security Group"
  }

  lifecycle {
    ignore_changes = [ingress]
  }
}

# Security group rule to allow Kafka service to access EFS
resource "aws_security_group_rule" "kafka_to_efs" {
  type                     = "ingress"
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  security_group_id        = aws_security_group.efs_kafka.id
  source_security_group_id = aws_security_group.kafka_service.id
  description              = "NFS from Kafka service"
}

# CloudWatch Log Group for Kafka Container
resource "aws_cloudwatch_log_group" "kafka_log_group" {
  name              = "kafka-logs"
  retention_in_days = 7

  tags = {
    Name      = "Kafka Logs"
    CreatedBy = "Terraform"
  }
}

# Service Discovery Namespace for internal services
resource "aws_service_discovery_private_dns_namespace" "base_services" {
  name        = "base-services.local"
  description = "Private DNS namespace for base services"
  vpc         = aws_vpc.base_vpc.id

  tags = {
    Name = "Base Services Namespace"
  }
}

# Service Discovery Service for Kafka
resource "aws_service_discovery_service" "kafka" {
  name = "kafka"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.base_services.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  # No health_check_custom_config block: its only argument, failure_threshold,
  # was deprecated in AWS provider v6 (AWS ignores the value and always uses 1).
  # Dropping it replaced this service — the block is ForceNew — so Kafka DNS
  # went down for the swap in 2026-07. Do not "restore" it as an empty
  # `health_check_custom_config {}`: AWS stores no config at all when the
  # argument is absent, so an empty block reads as a permanent diff and plans a
  # replacement on every run. Omit the block entirely.

  tags = {
    Name = "Kafka Service Discovery"
  }
}

# Security Group for Kafka Service
resource "aws_security_group" "kafka_service" {
  name        = "kafka-service-sg"
  description = "Security group for Kafka ECS service"
  vpc_id      = aws_vpc.base_vpc.id

  ingress {
    description     = "Kafka broker port from ECS tasks"
    from_port       = 9092
    to_port         = 9092
    protocol        = "tcp"
    security_groups = [aws_security_group.web_dmz.id]
  }

  ingress {
    description = "Kafka controller port (internal)"
    from_port   = 9093
    to_port     = 9093
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Kafka Service Security Group"
  }
}

# ECS Task Definition for Kafka
resource "aws_ecs_task_definition" "kafka_task" {
  family                   = "kafka"
  execution_role_arn       = aws_iam_role.ecs_task_role.arn
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]

  # Hosts are Graviton (t4g) — task scheduler must place this on an arm64 node.
  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  # EFS Volume for Kafka Data Persistence
  volume {
    name = "kafka-data"

    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.kafka_data.id
      transit_encryption = "ENABLED"

      authorization_config {
        iam = "DISABLED"
      }
    }
  }

  container_definitions = jsonencode([
    {
      name      = "kafka"
      image     = "confluentinc/cp-kafka:latest"
      cpu       = 512  # CPU units (~25% of t4g.large)
      memory    = 2048 # Memory in MB (~26% of t4g.large) — Confluent's default JVM heap is 1 GB; 768 MB OOMKilled the container on first start. 2 GB leaves headroom for off-heap + page cache.
      essential = true

      portMappings = [
        {
          containerPort = 9092
          protocol      = "tcp"
        },
        {
          containerPort = 9093
          protocol      = "tcp"
        }
      ]

      mountPoints = [
        {
          sourceVolume  = "kafka-data"
          containerPath = "/var/lib/kafka/data"
          readOnly      = false
        }
      ]

      environment = [
        {
          name  = "KAFKA_HEAP_OPTS"
          value = "-Xmx512m -Xms512m"
        },
        {
          name  = "KAFKA_LOG_DIRS"
          value = "/var/lib/kafka/data"
        },
        {
          name  = "KAFKA_NODE_ID"
          value = "1"
        },
        {
          name  = "KAFKA_PROCESS_ROLES"
          value = "broker,controller"
        },
        {
          name  = "KAFKA_CONTROLLER_QUORUM_VOTERS"
          value = "1@localhost:9093"
        },
        {
          name  = "KAFKA_LISTENERS"
          value = "PLAINTEXT://0.0.0.0:9092,CONTROLLER://localhost:9093"
        },
        {
          name  = "KAFKA_ADVERTISED_LISTENERS"
          value = "PLAINTEXT://kafka.base-services.local:9092"
        },
        {
          name  = "KAFKA_LISTENER_SECURITY_PROTOCOL_MAP"
          value = "PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT"
        },
        {
          name  = "KAFKA_CONTROLLER_LISTENER_NAMES"
          value = "CONTROLLER"
        },
        {
          name  = "KAFKA_INTER_BROKER_LISTENER_NAME"
          value = "PLAINTEXT"
        },
        {
          name  = "KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR"
          value = "1"
        },
        {
          name  = "KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR"
          value = "1"
        },
        {
          name  = "KAFKA_TRANSACTION_STATE_LOG_MIN_ISR"
          value = "1"
        },
        {
          name  = "KAFKA_AUTO_CREATE_TOPICS_ENABLE"
          value = "true"
        },
        {
          name  = "KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS"
          value = "0"
        },
        {
          name  = "CLUSTER_ID"
          value = "MkU3OEVBNTcwNTJENDM2Qk"
        }
      ]

      healthCheck = {
        command = [
          "CMD-SHELL",
          "kafka-broker-api-versions --bootstrap-server localhost:9092 || exit 1"
        ]
        interval    = 30
        timeout     = 10
        retries     = 5
        startPeriod = 60
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.kafka_log_group.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "kafka"
        }
      }
    }
  ])

  tags = {
    Name = "Kafka Task Definition"
  }
}

# ECS Service for Kafka
resource "aws_ecs_service" "kafka_service" {
  name            = "kafka-service"
  cluster         = aws_ecs_cluster.ecs_cluster.id
  desired_count   = 1
  launch_type     = "EC2"
  task_definition = aws_ecs_task_definition.kafka_task.arn

  # Stop-then-start: kafka holds an exclusive lock on its EFS data dir + KRaft
  # metadata, so two replicas cannot coexist even briefly. The default
  # max=200/min=100 tries to start a new task alongside the old one during
  # rolling deploys, which deadlocks (new task starts, fails to acquire the
  # log-dir lock, exits clean). Forcing max=100/min=0 makes ECS drain the
  # old task before scheduling the new one.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  # Both subnets: Kafka (awsvpc) can only be placed in the AZ of the single ECS
  # host, and the ASG may launch that host in either. EFS has a mount target in each.
  network_configuration {
    subnets         = [aws_subnet.public_subnet_a.id, aws_subnet.public_subnet_b.id]
    security_groups = [aws_security_group.kafka_service.id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.kafka.arn
  }

  # Placement strategy to keep Kafka on the same instance if possible
  ordered_placement_strategy {
    type  = "binpack"
    field = "memory"
  }

  tags = {
    Name = "Kafka ECS Service"
  }
}
