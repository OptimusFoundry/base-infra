# EventBridge Scheduler runs the two scheduled families on the shared cluster: daily-ingest at
# 06:00 New York time and the predictor every 15 minutes. One attempt each: the CLIs retry
# internally and exit 1 on failure, which the alarms in alarms.tf turn into mail.

resource "aws_iam_role" "scheduler" {
  name = "pmbot-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  # The name predates the predictor; renaming an inline policy replaces it.
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
          "arn:aws:ecs:${var.aws_region}:${local.account_id}:task-definition/pmbot-daily-ingest",
          "arn:aws:ecs:${var.aws_region}:${local.account_id}:task-definition/pmbot-daily-ingest:*",
        ]
        Condition = {
          ArnEquals = { "ecs:cluster" = local.cluster_id }
        }
      },
      {
        Sid    = "RunPredictorOnly"
        Effect = "Allow"
        Action = "ecs:RunTask"
        Resource = [
          "arn:aws:ecs:${var.aws_region}:${local.account_id}:task-definition/pmbot-predictor",
          "arn:aws:ecs:${var.aws_region}:${local.account_id}:task-definition/pmbot-predictor:*",
        ]
        Condition = {
          ArnEquals = { "ecs:cluster" = local.cluster_id }
        }
      },
      {
        Sid    = "PassOnlyThePmbotTaskRoles"
        Effect = "Allow"
        Action = "iam:PassRole"
        # Both scheduled families run as the model plane's role.
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
    arn      = local.cluster_id
    role_arn = aws_iam_role.scheduler.arn

    ecs_parameters {
      task_definition_arn    = aws_ecs_task_definition.svc["daily-ingest"].arn_without_revision
      task_count             = 1
      launch_type            = "EC2"
      enable_execute_command = true
    }

    retry_policy {
      maximum_retry_attempts = 0
    }
  }

  # pmbot-deploy points the target at each new revision. An apply must not point it back at the
  # family, whose latest revision may be a Terraform one with the bootstrap image.
  lifecycle {
    ignore_changes = [target[0].ecs_parameters[0].task_definition_arn]
  }
}

# A run that overlaps the previous one exits 0 and logs neither predictor_ok nor predictor_failed,
# so the staleness alarm still notices a predictor that always overlaps.
resource "aws_scheduler_schedule" "predictor" {
  name                         = "pmbot-predictor"
  schedule_expression          = "cron(0/15 * * * ? *)"
  schedule_expression_timezone = "America/New_York"
  state                        = var.predictor_enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = local.cluster_id
    role_arn = aws_iam_role.scheduler.arn

    ecs_parameters {
      task_definition_arn    = aws_ecs_task_definition.svc["predictor"].arn_without_revision
      task_count             = 1
      launch_type            = "EC2"
      enable_execute_command = true
    }

    retry_policy {
      maximum_retry_attempts = 0
    }
  }

  # Same reason as the daily-ingest schedule.
  lifecycle {
    ignore_changes = [target[0].ecs_parameters[0].task_definition_arn]
  }
}
