# Envelope-encryption key for secrets agentworks stores in its database
# (connector credentials, Claude login tokens). In production the server
# rejects a local SECRETS_KEY and refuses to boot without SECRETS_KMS_KEY_ID.
#
# prevent_destroy: destroying the key — even with the 30-day deletion window
# running out — makes every encrypted row in the database unreadable.

resource "aws_kms_key" "secrets" {
  description             = "agentworks database secret envelope key"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.product}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# Task role for the API container: the AWS SDK in base-server resolves KMS
# credentials from the ECS task-credentials endpoint. Scoped to this one key.
# S3 media access stays on the static-key IAM user (media-storage.tf), because
# base-server takes S3 credentials only as explicit env vars.
resource "aws_iam_role" "api_task" {
  name = "${var.product}-api-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "api_task_kms" {
  name = "secrets-kms"
  role = aws_iam_role.api_task.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "EnvelopeKey"
      Effect = "Allow"
      # The only two calls base-server's envelope cipher makes
      # (internal/infra/secrets/kms.go).
      Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
      Resource = aws_kms_key.secrets.arn
    }]
  })
}
