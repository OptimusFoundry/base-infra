# polymarket-bot EP-049 (D-029): the crypto taker, paper only.
#
#   pmbot-crypto-paper    ECS service (services.tf, local.services), desired 1, LIVE_TRADING=0 and no secret.
#   pmbot-crypto-scoring  scored hourly at :20 UTC by the schedule below.
#
# Both run as the pmbot-crypto-paper role: read and write crypto/ in the data bucket and nothing else, so no
# sports/ data and no AWS API beyond S3. They queue uploads on the paper plane (SPORTS_S3_QUEUE=paper).
# Nothing under crypto/ may expire: the journals (crypto/paper/journal/) and the trade table
# (crypto/paper/trades/) are the permanent record. The data bucket is not managed here; on 2026-10-06 its
# lifecycle rules matched only lfs-archive/, sports/ (noncurrent versions) and incomplete multipart uploads.

resource "aws_iam_role" "crypto" {
  name = "pmbot-crypto-paper"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "crypto" {
  name = "pmbot-crypto-paper"
  role = aws_iam_role.crypto.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadWriteCrypto"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = "arn:aws:s3:::${var.data_bucket}/crypto/*"
      },
      {
        Sid      = "ListCrypto"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${var.data_bucket}"
        Condition = {
          StringLike = { "s3:prefix" = ["crypto/*"] }
        }
      },
      {
        # Same guard as every plane role (iam.tf): the permanent record cannot be deleted from a task.
        Sid    = "NeverDeleteOrReconfigure"
        Effect = "Deny"
        Action = [
          "s3:Delete*",
          "s3:PutBucket*",
          "s3:PutLifecycleConfiguration",
        ]
        Resource = [
          "arn:aws:s3:::${var.data_bucket}",
          "arn:aws:s3:::${var.data_bucket}/*",
        ]
      },
    ]
  })
}

resource "aws_scheduler_schedule" "crypto_scoring" {
  name                         = "pmbot-crypto-scoring"
  schedule_expression          = "cron(20 * * * ? *)"
  schedule_expression_timezone = "UTC"
  state                        = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = local.cluster_id
    role_arn = aws_iam_role.scheduler.arn

    ecs_parameters {
      task_definition_arn = aws_ecs_task_definition.svc["crypto-scoring"].arn_without_revision
      task_count          = 1
      launch_type         = "EC2"
    }

    retry_policy {
      maximum_retry_attempts = 0
    }
  }

  # pmbot-deploy re-points the schedule at the revision it registers (schedule.tf, daily-ingest).
  lifecycle {
    ignore_changes = [target[0].ecs_parameters[0].task_definition_arn]
  }
}

# polymarket-bot EP-050: pmbot-crypto-recorder (services.tf, local.services) records public market data, paper only and
# with no secret. Its own role, narrower than pmbot-crypto-paper: read and write crypto/recorder/ and nothing else, so
# it cannot reach the taker's journals (crypto/paper/) or anything under sports/. Only zstd parquet is uploaded, and
# nothing under crypto/ expires (the bucket's lifecycle rules, above).
resource "aws_iam_role" "crypto_recorder" {
  name = "pmbot-crypto-recorder"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "crypto_recorder" {
  name = "pmbot-crypto-recorder"
  role = aws_iam_role.crypto_recorder.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadWriteCryptoRecorder"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "arn:aws:s3:::${var.data_bucket}/crypto/recorder/*"
      },
      {
        Sid      = "ListCryptoRecorder"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${var.data_bucket}"
        Condition = {
          StringLike = { "s3:prefix" = ["crypto/recorder/*"] }
        }
      },
      {
        # Same guard as every plane role (iam.tf): the permanent record cannot be deleted from a task.
        Sid    = "NeverDeleteOrReconfigure"
        Effect = "Deny"
        Action = [
          "s3:Delete*",
          "s3:PutBucket*",
          "s3:PutLifecycleConfiguration",
        ]
        Resource = [
          "arn:aws:s3:::${var.data_bucket}",
          "arn:aws:s3:::${var.data_bucket}/*",
        ]
      },
    ]
  })
}
