# Roles polymarket-bot's GitHub Actions assume through OIDC (main branch only, no secrets):
#
#   pmbot-github-ecr-push  push images to the pmbot repository. Nothing else.
#   pmbot-github-deploy    register task definitions, update the pmbot services, re-point the two
#                          schedules, and upload + invalidate the status site (never status.json).
#   pmbot-github-research-run  start research tasks (pmbot-research, pmbot-research-fargate) on the shared
#                          cluster, follow them and read their log (polymarket-bot EP-034, CH-011; the "Run
#                          research job" workflow only).
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
        # The execution role and the four per-plane task roles (the legacy pmbot-task role is gone, CHORE-017).
        Sid    = "PassTheTaskRoles"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = concat(
          [aws_iam_role.task_execution.arn],
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
        # polymarket-bot CH-012: ecs_deploy.py re-points pmbot-scoring like the predictor (an OPTIONAL schedule there).
        Sid      = "RepointTheScoringSchedule"
        Effect   = "Allow"
        Action   = ["scheduler:GetSchedule", "scheduler:UpdateSchedule"]
        Resource = "arn:aws:scheduler:${var.aws_region}:${local.account_id}:schedule/default/pmbot-scoring"
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

# The role polymarket-bot's "Run research job" workflow (.github/workflows/pmbot-research.yml) assumes. It can start
# the two research families on the shared cluster (pmbot-research here; pmbot-research-fargate in
# github_research_run_fargate below, CH-011), list and look at the cluster's tasks, read the research network
# parameter and the research log group. It cannot register or stop anything, pass any other role, touch S3 or IAM,
# read any other SSM parameter, or run a vault runner (the workflow offers none, and the job refuses one without the
# owner's PMBOT_VAULT_GO).
resource "aws_iam_role" "github_research_run" {
  name = "pmbot-github-research-run"

  # main of the repository (the immutable subject, as the push and deploy roles) and only the one workflow file on
  # main: a branch, a pull request or another workflow cannot assume it. The event name is not an AWS condition
  # key; workflow_dispatch is the workflow file's only trigger (polymarket-bot test_research_workflow.py).
  # 10800 s: the launcher tails a job's log for as long as it runs (the workflow sets role-duration-seconds).
  max_session_duration = 10800

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud"              = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub"              = local.github_subject
          "token.actions.githubusercontent.com:job_workflow_ref" = "${var.github_repo}/.github/workflows/pmbot-research.yml@refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_research_run" {
  name = "run-research-job"
  role = aws_iam_role.github_research_run.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Both forms, as the scheduler's statements: the family ARN and every revision, on the shared cluster only.
        # DescribeTaskDefinition is deliberately absent (no resource-level permissions): the launcher pins family,
        # container, log group and stream prefix as constants (run.py).
        Sid    = "RunTheResearchTask"
        Effect = "Allow"
        Action = "ecs:RunTask"
        Resource = [
          "arn:aws:ecs:${var.aws_region}:${local.account_id}:task-definition/pmbot-research",
          "arn:aws:ecs:${var.aws_region}:${local.account_id}:task-definition/pmbot-research:*",
        ]
        Condition = {
          ArnEquals = { "ecs:cluster" = local.cluster_id }
        }
      },
      {
        # Task ids are random, so this is every task in the shared cluster (read-only status; no secret values).
        Sid      = "DescribeTheClustersTasks"
        Effect   = "Allow"
        Action   = "ecs:DescribeTasks"
        Resource = "arn:aws:ecs:${var.aws_region}:${local.account_id}:task/${local.cluster_name}/*"
      },
      {
        # RunTask passes the task role and the execution role of the revision it starts.
        Sid      = "PassTheResearchTaskRoles"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = [aws_iam_role.plane["research"].arn, aws_iam_role.task_execution.arn]
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
      {
        # GetLogEvents is evaluated against the stream ARN (log-group:<name>:log-stream:<stream>), which the second
        # form covers. Literal ARNs: the group's .arn is unknown until apply and would hide this policy in the plan.
        Sid    = "ReadTheResearchLogs"
        Effect = "Allow"
        Action = "logs:GetLogEvents"
        Resource = [
          "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/ecs/pmbot/research",
          "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/ecs/pmbot/research:*",
        ]
      },
    ]
  })
}

# CH-011: the parallel Fargate family. A separate inline policy, so the owner's plan shows only additions. No new
# PassRole: the Fargate family runs with the same research task role and execution role (PassTheResearchTaskRoles).
resource "aws_iam_role_policy" "github_research_run_fargate" {
  name = "run-research-fargate"
  role = aws_iam_role.github_research_run.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RunTheFargateResearchTask"
        Effect = "Allow"
        Action = "ecs:RunTask"
        Resource = [
          "arn:aws:ecs:${var.aws_region}:${local.account_id}:task-definition/pmbot-research-fargate",
          "arn:aws:ecs:${var.aws_region}:${local.account_id}:task-definition/pmbot-research-fargate:*",
        ]
        Condition = {
          ArnEquals = { "ecs:cluster" = local.cluster_id }
        }
      },
      {
        # The launcher's concurrency cap and `list`: list-tasks --cluster ecs-cluster --family <research family>.
        # Read-only task ARNs; "*" because ListTasks names no task resource.
        Sid      = "CountTheResearchJobs"
        Effect   = "Allow"
        Action   = "ecs:ListTasks"
        Resource = "*"
      },
      {
        # The awsvpc subnets and security group of a Fargate job (research-fargate.tf), and nothing else. A literal
        # ARN: the parameter's .arn is unknown until apply and would hide this policy in the plan.
        Sid      = "ReadTheResearchNetwork"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter/${local.name}/research-fargate/network"
      },
    ]
  })
}
