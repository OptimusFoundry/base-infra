# Continuous-delivery roles (polymarket-bot CH-008). All three are assumed through GitHub OIDC with the
# shared provider read in github-oidc.tf (data.aws_iam_openid_connect_provider.github); no secret exists.
#
#   pmbot-github-deploy          polymarket-bot main: describe + register task definitions, update the
#                                pmbot services, re-point the daily-ingest and predictor schedules, and
#                                upload + invalidate the status site (CH-009; never status.json). Nothing else.
#   pmbot-github-terraform       base-infra main: plan and apply this stack (pmbot-named resources only).
#   pmbot-github-terraform-plan  base-infra pull requests: read-only plan. A pull_request run uses the
#                                PR's own workflow file, so this role must not be able to write anything.
#
# Created once by a saved-plan apply from a workstation (README "Bootstrap"). plan_guard.py refuses any
# CI change to a github_* role or policy, and the apply role is denied IAM writes on pmbot-github-*, so
# CD never widens its own permissions.

locals {
  account_id = data.aws_caller_identity.current.account_id
  ecs_arn    = "arn:aws:ecs:${var.aws_region}:${local.account_id}"
  ec2_arn    = "arn:aws:ec2:${var.aws_region}:${local.account_id}"

  state_bucket          = "pmbot-terraform-state"
  platform_state_bucket = "protoapp-infra-terraform-state"
  platform_state_key    = "state/terraform.tfstate"

  base_infra_main_subject = "${var.base_infra_oidc_subject_prefix}:ref:refs/heads/main"
  base_infra_pr_subject   = "${var.base_infra_oidc_subject_prefix}:pull_request"

  # Everything a plan of this stack reads. Shared by the plan role and the apply role.
  terraform_read_statements = [
    {
      Sid      = "StateBucketList"
      Effect   = "Allow"
      Action   = ["s3:ListBucket"]
      Resource = "arn:aws:s3:::${local.state_bucket}"
    },
    {
      Sid      = "StateRead"
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "arn:aws:s3:::${local.state_bucket}/state/*"
    },
    {
      Sid      = "PlatformStateRead"
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "arn:aws:s3:::${local.platform_state_bucket}/${local.platform_state_key}"
    },
    {
      Sid      = "PlatformStateList"
      Effect   = "Allow"
      Action   = ["s3:ListBucket"]
      Resource = "arn:aws:s3:::${local.platform_state_bucket}"
      Condition = {
        StringLike = { "s3:prefix" = ["state/*", "env:/*"] }
      }
    },
    {
      # Describe/List calls have no resource-level permissions for most of these services.
      Sid    = "DescribeWhatThisStackReads"
      Effect = "Allow"
      Action = [
        "ecs:Describe*",
        "ecs:List*",
        "ec2:Describe*",
        "ec2:GetLaunchTemplateData",
        "autoscaling:Describe*",
        "cloudwatch:DescribeAlarms",
        "cloudwatch:ListTagsForResource",
        "logs:DescribeLogGroups",
        "logs:DescribeMetricFilters",
        "logs:ListTagsForResource",
        "logs:ListTagsLogGroup",
        "iam:ListOpenIDConnectProviders",
      ]
      Resource = "*"
    },
    {
      Sid      = "ReadPmbotEcr"
      Effect   = "Allow"
      Action   = ["ecr:DescribeRepositories", "ecr:GetLifecyclePolicy", "ecr:GetRepositoryPolicy", "ecr:ListTagsForResource"]
      Resource = "arn:aws:ecr:${var.aws_region}:${local.account_id}:repository/${local.name}"
    },
    {
      Sid    = "ReadPmbotIam"
      Effect = "Allow"
      Action = [
        "iam:GetRole",
        "iam:GetRolePolicy",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:ListRoleTags",
        "iam:ListInstanceProfilesForRole",
        "iam:GetInstanceProfile",
        "iam:ListInstanceProfileTags",
      ]
      Resource = [
        "arn:aws:iam::${local.account_id}:role/pmbot-*",
        "arn:aws:iam::${local.account_id}:instance-profile/pmbot-*",
      ]
    },
    {
      Sid      = "ReadGithubOidcProvider"
      Effect   = "Allow"
      Action   = ["iam:GetOpenIDConnectProvider", "iam:ListOpenIDConnectProviderTags"]
      Resource = data.aws_iam_openid_connect_provider.github.arn
    },
    {
      Sid      = "ReadPmbotSchedules"
      Effect   = "Allow"
      Action   = ["scheduler:GetSchedule", "scheduler:ListTagsForResource"]
      Resource = "arn:aws:scheduler:${var.aws_region}:${local.account_id}:schedule/default/pmbot-*"
    },
    {
      Sid      = "ReadEcsAmiParameter"
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters"]
      Resource = "arn:aws:ssm:${var.aws_region}::parameter/aws/service/ecs/*"
    },
    {
      # CH-009: refreshing the status site bucket (bucket-level Get/List only; no object read).
      Sid    = "ReadTheSiteBucket"
      Effect = "Allow"
      Action = [
        "s3:GetBucket*",
        "s3:GetAccelerateConfiguration",
        "s3:GetEncryptionConfiguration",
        "s3:GetLifecycleConfiguration",
        "s3:GetReplicationConfiguration",
        "s3:ListBucket",
      ]
      Resource = "arn:aws:s3:::${local.site_bucket}"
    },
    {
      # CH-009: CloudFront reads have no useful resource scoping across distributions and OACs.
      Sid      = "ReadCloudFront"
      Effect   = "Allow"
      Action   = ["cloudfront:Get*", "cloudfront:List*"]
      Resource = "*"
    },
  ]

  # Writes, for the apply role only: pmbot-named (or Product=pmbot-tagged) resources of this stack.
  terraform_write_statements = [
    {
      Sid      = "StateWriteAndLock"
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:DeleteObject"]
      Resource = "arn:aws:s3:::${local.state_bucket}/state/*"
    },
    {
      # No resource-level permissions exist for these two.
      Sid      = "TaskDefinitionsRegister"
      Effect   = "Allow"
      Action   = ["ecs:RegisterTaskDefinition", "ecs:DeregisterTaskDefinition"]
      Resource = "*"
    },
    {
      Sid    = "ManagePmbotEcs"
      Effect = "Allow"
      Action = ["ecs:*"]
      Resource = [
        "${local.ecs_arn}:cluster/${local.name}",
        "${local.ecs_arn}:service/${local.name}/*",
        "${local.ecs_arn}:capacity-provider/${local.name}",
        "${local.ecs_arn}:task-definition/pmbot-*:*",
      ]
    },
    {
      Sid      = "ManagePmbotEcr"
      Effect   = "Allow"
      Action   = ["ecr:*"]
      Resource = "arn:aws:ecr:${var.aws_region}:${local.account_id}:repository/${local.name}"
    },
    {
      Sid      = "ManagePmbotAsg"
      Effect   = "Allow"
      Action   = ["autoscaling:*"]
      Resource = "arn:aws:autoscaling:${var.aws_region}:${local.account_id}:autoScalingGroup:*:autoScalingGroupName/pmbot-ecs-*"
    },
    {
      Sid      = "CreatePmbotTaggedEc2"
      Effect   = "Allow"
      Action   = ["ec2:CreateLaunchTemplate", "ec2:CreateSecurityGroup"]
      Resource = ["${local.ec2_arn}:launch-template/*", "${local.ec2_arn}:security-group/*"]
      Condition = {
        StringEquals = { "aws:RequestTag/Product" = var.product }
      }
    },
    {
      Sid      = "CreateSecurityGroupInPlatformVpc"
      Effect   = "Allow"
      Action   = ["ec2:CreateSecurityGroup"]
      Resource = "${local.ec2_arn}:vpc/${local.vpc_id}"
    },
    {
      Sid      = "TagOnCreate"
      Effect   = "Allow"
      Action   = ["ec2:CreateTags"]
      Resource = ["${local.ec2_arn}:launch-template/*", "${local.ec2_arn}:security-group/*"]
      Condition = {
        StringEquals = { "ec2:CreateAction" = ["CreateLaunchTemplate", "CreateSecurityGroup"] }
      }
    },
    {
      # Egress only: the role cannot open an ingress rule on the pmbot host.
      Sid    = "ManagePmbotTaggedEc2"
      Effect = "Allow"
      Action = [
        "ec2:CreateLaunchTemplateVersion",
        "ec2:ModifyLaunchTemplate",
        "ec2:DeleteLaunchTemplate",
        "ec2:DeleteLaunchTemplateVersions",
        "ec2:AuthorizeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupEgress",
        "ec2:UpdateSecurityGroupRuleDescriptionsEgress",
        "ec2:DeleteSecurityGroup",
        "ec2:CreateTags",
        "ec2:DeleteTags",
      ]
      Resource = ["${local.ec2_arn}:launch-template/*", "${local.ec2_arn}:security-group/*"]
      Condition = {
        StringEquals = { "aws:ResourceTag/Product" = var.product }
      }
    },
    {
      Sid      = "EgressRules"
      Effect   = "Allow"
      Action   = ["ec2:AuthorizeSecurityGroupEgress", "ec2:RevokeSecurityGroupEgress"]
      Resource = "${local.ec2_arn}:security-group-rule/*"
    },
    {
      # EC2 Auto Scaling checks RunInstances on the launch template when the group's template version
      # changes (AMI drift). Limited to the pmbot template (owner decision D5).
      Sid      = "AsgUsesThePmbotLaunchTemplate"
      Effect   = "Allow"
      Action   = ["ec2:RunInstances"]
      Resource = "*"
      Condition = {
        ArnLike = { "ec2:LaunchTemplate" = aws_launch_template.instance.arn }
        Bool    = { "ec2:IsLaunchTemplateResource" = "true" }
      }
    },
    {
      Sid    = "ManagePmbotIam"
      Effect = "Allow"
      Action = ["iam:*"]
      Resource = [
        "arn:aws:iam::${local.account_id}:role/pmbot-*",
        "arn:aws:iam::${local.account_id}:instance-profile/pmbot-*",
      ]
    },
    {
      Sid      = "ManagePmbotSchedules"
      Effect   = "Allow"
      Action   = ["scheduler:*"]
      Resource = "arn:aws:scheduler:${var.aws_region}:${local.account_id}:schedule/default/pmbot-*"
    },
    {
      Sid      = "ManagePmbotAlarms"
      Effect   = "Allow"
      Action   = ["cloudwatch:*"]
      Resource = "arn:aws:cloudwatch:${var.aws_region}:${local.account_id}:alarm:pmbot-*"
    },
    {
      Sid    = "ManagePmbotLogGroups"
      Effect = "Allow"
      Action = ["logs:*"]
      Resource = [
        "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/ecs/pmbot/*",
        "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/ecs/pmbot/*:*",
      ]
    },
    {
      # CH-009: the status site bucket, by name.
      Sid      = "ManageTheSiteBucket"
      Effect   = "Allow"
      Action   = ["s3:*"]
      Resource = ["arn:aws:s3:::${local.site_bucket}", "arn:aws:s3:::${local.site_bucket}/*"]
    },
    {
      # CH-009: edits to the pmbot distribution only (it carries the Product=pmbot default tag). Creating a
      # distribution or an OAC is an owner apply.
      Sid    = "ManageThePmbotDistribution"
      Effect = "Allow"
      Action = [
        "cloudfront:UpdateDistribution",
        "cloudfront:DeleteDistribution",
        "cloudfront:TagResource",
        "cloudfront:UntagResource",
        "cloudfront:CreateInvalidation",
      ]
      Resource = "arn:aws:cloudfront::${local.account_id}:distribution/*"
      Condition = {
        StringEquals = { "aws:ResourceTag/Product" = var.product }
      }
    },
    {
      Sid    = "NeverEditTheCdRoles"
      Effect = "Deny"
      Action = [
        "iam:Attach*",
        "iam:Create*",
        "iam:Delete*",
        "iam:Detach*",
        "iam:Put*",
        "iam:Tag*",
        "iam:Untag*",
        "iam:Update*",
      ]
      Resource = "arn:aws:iam::${local.account_id}:role/pmbot-github-*"
    },
    {
      Sid    = "NeverReconfigureTheStateBucket"
      Effect = "Deny"
      Action = [
        "s3:DeleteBucket*",
        "s3:PutBucket*",
        "s3:PutLifecycleConfiguration",
        "s3:PutEncryptionConfiguration",
        "s3:DeleteObjectVersion",
      ]
      Resource = ["arn:aws:s3:::${local.state_bucket}", "arn:aws:s3:::${local.state_bucket}/*"]
    },
  ]
}

# --- polymarket-bot app deploys ---

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
        Resource = "${local.ecs_arn}:task-definition/pmbot-*:*"
      },
      {
        # Keep the Product=pmbot cost tag on CI-registered revisions (owner decision D4).
        Sid      = "TagTaskDefinitionsOnRegister"
        Effect   = "Allow"
        Action   = ["ecs:TagResource"]
        Resource = "${local.ecs_arn}:task-definition/pmbot-*:*"
        Condition = {
          StringEquals = { "ecs:CreateAction" = "RegisterTaskDefinition" }
        }
      },
      {
        Sid      = "UpdatePmbotServices"
        Effect   = "Allow"
        Action   = ["ecs:UpdateService"]
        Resource = "${local.ecs_arn}:service/${local.name}/pmbot-*"
      },
      {
        # EP-031: the four per-plane task roles. Literal ARNs, not aws_iam_role.plane[...].arn, so this
        # owner-applied change needs none of them to exist yet. pmbot-task-live is not listed (EP-033).
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
        # UpdateSchedule passes the target's role (owner decision D4).
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
        # EP-030: pmbot-deploy re-points the predictor schedule the same way. A literal ARN, not
        # aws_scheduler_schedule.predictor.arn, so this owner-applied change needs no schedule to exist yet.
        Sid      = "RepointThePredictorSchedule"
        Effect   = "Allow"
        Action   = ["scheduler:GetSchedule", "scheduler:UpdateSchedule"]
        Resource = "arn:aws:scheduler:${var.aws_region}:${local.account_id}:schedule/default/pmbot-predictor"
      },
      {
        # CH-009: registering pmbot-status revisions passes its task role.
        Sid      = "PassTheStatusTaskRole"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = aws_iam_role.status.arn
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
      {
        # CH-009: pmbot-site.yml lists the bucket for `aws s3 sync`.
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

# --- base-infra Terraform CD for this stack ---

resource "aws_iam_role" "github_terraform" {
  name = "pmbot-github-terraform"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.base_infra_main_subject
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_terraform" {
  name = "terraform-pmbot-apply"
  role = aws_iam_role.github_terraform.name

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = concat(local.terraform_read_statements, local.terraform_write_statements)
  })
}

resource "aws_iam_role" "github_terraform_plan" {
  name = "pmbot-github-terraform-plan"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.base_infra_pr_subject
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_terraform_plan" {
  name = "terraform-pmbot-plan"
  role = aws_iam_role.github_terraform_plan.name

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.terraform_read_statements
  })
}

output "github_deploy_role_arn" {
  value       = aws_iam_role.github_deploy.arn
  description = "PMBOT_DEPLOY_ROLE_ARN repository variable in OptimusFoundry/polymarket-bot"
}

output "github_terraform_role_arn" {
  value       = aws_iam_role.github_terraform.arn
  description = "PMBOT_TF_APPLY_ROLE_ARN repository variable in OptimusFoundry/base-infra"
}

output "github_terraform_plan_role_arn" {
  value       = aws_iam_role.github_terraform_plan.arn
  description = "PMBOT_TF_PLAN_ROLE_ARN repository variable in OptimusFoundry/base-infra"
}
