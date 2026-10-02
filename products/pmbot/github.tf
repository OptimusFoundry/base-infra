# Roles polymarket-bot's GitHub Actions assume through OIDC (main branch only, no secrets):
#
#   pmbot-github-ecr-push  push images to the pmbot repository. Nothing else.
#   pmbot-github-deploy    register task definitions, update the pmbot services, re-point the two
#                          schedules, and upload + invalidate the status site (never status.json).
#
# The OIDC provider is shared and unmanaged, so it is read as a data source, as platform/github-oidc.tf
# does. Unlike the other products, which deploy through platform's admin role, these are scoped to
# pmbot-named resources.

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  github_subject = coalesce(var.github_oidc_subject, "repo:${var.github_repo}:ref:refs/heads/main")
}

resource "aws_iam_role" "github_push" {
  name = "pmbot-github-ecr-push"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.github_subject
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_push" {
  name = "ecr-push"
  role = aws_iam_role.github_push.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "PushToPmbotOnly"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:DescribeImages",
        ]
        Resource = aws_ecr_repository.pmbot.arn
      },
    ]
  })
}

resource "aws_iam_role" "github_deploy" {
  name = "pmbot-github-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.github_subject
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_deploy" {
  name = "ecs-deploy"
  role = aws_iam_role.github_deploy.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # DescribeTaskDefinition has no resource-level permissions.
        Sid      = "DescribeEcs"
        Effect   = "Allow"
        Action   = ["ecs:Describe*"]
        Resource = "*"
      },
      {
        # RegisterTaskDefinition has no resource-level permissions.
        Sid      = "RegisterTaskDefinitions"
        Effect   = "Allow"
        Action   = ["ecs:RegisterTaskDefinition"]
        Resource = "*"
      },
      {
        # `describe-task-definition --include TAGS` reads the revision's tags.
        Sid      = "ReadTaskDefinitionTags"
        Effect   = "Allow"
        Action   = ["ecs:ListTagsForResource"]
        Resource = "arn:aws:ecs:${var.aws_region}:${local.account_id}:task-definition/pmbot-*:*"
      },
      {
        # Keep the Product=pmbot cost tag on CI-registered revisions.
        Sid      = "TagTaskDefinitionsOnRegister"
        Effect   = "Allow"
        Action   = ["ecs:TagResource"]
        Resource = "arn:aws:ecs:${var.aws_region}:${local.account_id}:task-definition/pmbot-*:*"
        Condition = {
          StringEquals = { "ecs:CreateAction" = "RegisterTaskDefinition" }
        }
      },
      {
        Sid      = "UpdatePmbotServices"
        Effect   = "Allow"
        Action   = ["ecs:UpdateService"]
        Resource = "arn:aws:ecs:${var.aws_region}:${local.account_id}:service/${local.cluster_name}/pmbot-*"
      },
      {
        # The legacy role, the execution role and the four per-plane task roles.
        Sid    = "PassTheTaskRoles"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = concat(
          [aws_iam_role.task.arn, aws_iam_role.task_execution.arn],
          [for plane in ["collect", "model", "paper", "research"] : "arn:aws:iam::${local.account_id}:role/pmbot-task-${plane}"],
        )
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
      {
        # UpdateSchedule passes the target's role.
        Sid      = "PassTheSchedulerRole"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = aws_iam_role.scheduler.arn
        Condition = {
          StringEquals = { "iam:PassedToService" = "scheduler.amazonaws.com" }
        }
      },
      {
        Sid      = "RepointTheDailyIngestSchedule"
        Effect   = "Allow"
        Action   = ["scheduler:GetSchedule", "scheduler:UpdateSchedule"]
        Resource = aws_scheduler_schedule.daily_ingest.arn
      },
      {
        Sid      = "RepointThePredictorSchedule"
        Effect   = "Allow"
        Action   = ["scheduler:GetSchedule", "scheduler:UpdateSchedule"]
        Resource = "arn:aws:scheduler:${var.aws_region}:${local.account_id}:schedule/default/pmbot-predictor"
      },
      {
        # Registering pmbot-status revisions passes its task role.
        Sid      = "PassTheStatusTaskRole"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = aws_iam_role.status.arn
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
      {
        # pmbot-site.yml lists the bucket for `aws s3 sync`.
        Sid      = "ListTheSiteBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.site.arn
      },
      {
        # The page, its scoreboard and its hashed assets. Never status.json: the pmbot-status task owns it.
        Sid    = "UploadTheSite"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:DeleteObject"]
        Resource = [
          "${aws_s3_bucket.site.arn}/index.html",
          "${aws_s3_bucket.site.arn}/scoreboard.json",
          "${aws_s3_bucket.site.arn}/assets/*",
        ]
      },
      {
        Sid      = "InvalidateTheSite"
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
        Resource = aws_cloudfront_distribution.site.arn
      },
    ]
  })
}
