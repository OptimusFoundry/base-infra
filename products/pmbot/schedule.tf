# Daily ingest: 06:00 New York time, one task of the pmbot-daily-ingest revision pmbot-deploy last
# pointed it at (the family's latest ACTIVE revision until the first CI deploy), on the dedicated
# pmbot cluster via its capacity provider.
# One attempt only: the CLI retries 429s itself (T7) and exits 1 on failure, which the
# alarms in alarms.tf turn into mail.

resource "aws_iam_role" "scheduler" {
  name = "pmbot-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  # The name stays "run-daily-ingest" (renaming an inline policy replaces it); it now also covers the predictor.
  name = "run-daily-ingest"
  role = aws_iam_role.scheduler.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RunDailyIngestOnly"
        Effect = "Allow"
        Action = "ecs:RunTask"
        # both forms: the family ARN (a revision-less RunTask target) and every revision of it
        Resource = [
          "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/pmbot-daily-ingest",
          "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/pmbot-daily-ingest:*",
        ]
        Condition = {
          ArnEquals = { "ecs:cluster" = local.cluster_arn }
        }
      },
      {
        Sid    = "RunPredictorOnly"
        Effect = "Allow"
        Action = "ecs:RunTask"
        Resource = [
          "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/pmbot-predictor",
          "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/pmbot-predictor:*",
        ]
        Condition = {
          ArnEquals = { "ecs:cluster" = local.cluster_arn }
        }
      },
      {
        Sid    = "PassOnlyThePmbotTaskRoles"
        Effect = "Allow"
        Action = "iam:PassRole"
        # EP-031: the scheduled families (daily-ingest, predictor) run as the model plane's role once
        # pmbot-deploy re-points their schedules at the per-plane revisions.
        Resource = [
          aws_iam_role.task.arn,
          aws_iam_role.task_execution.arn,
          aws_iam_role.plane["model"].arn,
        ]
        Condition = {
          StringLike = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
    ]
  })
}

resource "aws_scheduler_schedule" "daily_ingest" {
  name                         = "pmbot-daily-ingest"
  schedule_expression          = "cron(0 6 * * ? *)"
  schedule_expression_timezone = "America/New_York"
  state                        = var.daily_ingest_enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = local.cluster_arn
    role_arn = aws_iam_role.scheduler.arn

    ecs_parameters {
      task_definition_arn    = aws_ecs_task_definition.daily_ingest.arn_without_revision
      task_count             = 1
      enable_execute_command = true

      # Dedicated cluster (D1 = b): capacity provider strategy, never launch_type, matching
      # the services in services.tf.
      capacity_provider_strategy {
        capacity_provider = aws_ecs_capacity_provider.pmbot.name
        weight            = 1
        base              = 1
      }

      placement_constraints {
        type       = "memberOf"
        expression = local.placement_expression
      }
    }

    retry_policy {
      maximum_retry_attempts = 0
    }
  }

  # pmbot-deploy (polymarket-bot CH-008) points the target at each new daily-ingest revision. An apply
  # must not point it back at the family, whose latest revision may be a Terraform one with the
  # bootstrap image.
  lifecycle {
    ignore_changes = [target[0].ecs_parameters[0].task_definition_arn]
  }
}

# Predictor (EP-030): every 15 minutes, one task of the pmbot-predictor revision pmbot-deploy last pointed
# it at (the family's latest ACTIVE revision, which runs the bootstrap image, until the first deploy after
# this stack is applied). Ships DISABLED (var.predictor_enabled, default false); the owner enables it by PR
# after one verified manual run. One attempt only: the CLI exits 1 on failure and the alarms in alarms.tf
# turn that into mail, and the next slot is 15 minutes away. A run that overlaps the previous one exits 0
# and logs neither predictor_ok nor predictor_failed (plan R9), so the staleness alarm still sees it.
resource "aws_scheduler_schedule" "predictor" {
  name                         = "pmbot-predictor"
  schedule_expression          = "cron(0/15 * * * ? *)"
  schedule_expression_timezone = "America/New_York"
  state                        = var.predictor_enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = local.cluster_arn
    role_arn = aws_iam_role.scheduler.arn

    ecs_parameters {
      task_definition_arn    = aws_ecs_task_definition.predictor.arn_without_revision
      task_count             = 1
      enable_execute_command = true

      capacity_provider_strategy {
        capacity_provider = aws_ecs_capacity_provider.pmbot.name
        weight            = 1
        base              = 1
      }

      placement_constraints {
        type       = "memberOf"
        expression = local.placement_expression
      }
    }

    retry_policy {
      maximum_retry_attempts = 0
    }
  }

  # pmbot-deploy points the target at each new pmbot-predictor revision; an apply must not point it back
  # at the family (same reason as the daily-ingest schedule).
  lifecycle {
    ignore_changes = [target[0].ecs_parameters[0].task_definition_arn]
  }
}
