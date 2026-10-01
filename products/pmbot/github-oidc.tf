# The role polymarket-bot's GitHub Actions workflow assumes via OIDC to push the image.
# It can push to the pmbot repository only and cannot deploy (no ECS, IAM or Terraform
# permission). The OIDC provider is shared and unmanaged, so it is read as a data
# source, exactly as platform/github-oidc.tf:12-14 does.

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

output "github_push_role_arn" {
  value       = aws_iam_role.github_push.arn
  description = "Role ARN for the PMBOT_ECR_PUSH_ROLE_ARN repository variable in GitHub"
}
