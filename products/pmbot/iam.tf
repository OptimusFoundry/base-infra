# Task roles: what the containers may do. Execution role: what ECS may do to start them (pull the
# image, write logs). No secret reaches any task, and no role here may read SSM parameters.
#
# One task role per plane (pmbot-task-<plane>), each allowed to PutObject only under its own key
# prefixes of the data bucket, never to delete.

locals {
  # write_prefixes are key prefixes under the bucket's sports/ prefix, i.e. paths relative to
  # SPORTS_DATA_ROOT. exec: the plane's tasks run with enable_execute_command, so the role needs the
  # ssmmessages channels (a debug shell, not parameter access).
  planes = {
    collect = {
      exec           = true
      write_prefixes = ["recorder/", "collectors/"]
    }
    model = {
      exec           = true
      write_prefixes = ["nba/", "nhl/", "predictions/", "recorder/nba_injury/"]
    }
    paper = {
      # nba/injury_parsed/: the inline maker path's injury-PDF parse cache.
      exec           = true
      write_prefixes = ["live/maker/journal.paper.", "live/prices/", "live/tape/", "nba/injury_parsed/"]
    }
    research = {
      exec = false
      write_prefixes = [
        "experiments/", "panel/", "gamma/", "prices/", "pretrades/", "tape/", "hist/", "nba/", "nhl/",
        "nfl/", "ncaab/", "collectors/xvenue/",
      ]
    }
  }

  # Key prefixes under sports/ a plane may PutObject to only while the request carries If-None-Match: * (a create
  # that fails when the key exists: no overwrite). The research plane's durable ledger (polymarket-bot EP-034):
  # one immutable object per record under sports/ledger/records/. sports/ledger.jsonl, the owner's backup
  # snapshot, is no longer writable by any task role. Kept out of local.planes on purpose: its attribute set must
  # stay identical across planes for for_each.
  plane_create_only_prefixes = tomap({
    research = ["ledger/records/"]
  })
}

resource "aws_iam_role" "plane" {
  for_each = local.planes

  name = "pmbot-task-${each.key}"

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

# Reads stay bucket-wide under sports/; writes are object ARNs under the plane's own prefixes;
# deletes and bucket changes are denied outright.
resource "aws_iam_role_policy" "plane" {
  for_each = local.planes

  name = "pmbot-task-${each.key}"
  role = aws_iam_role.plane[each.key].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "ReadData"
          Effect   = "Allow"
          Action   = ["s3:GetObject"]
          Resource = "arn:aws:s3:::${var.data_bucket}/sports/*"
        },
        {
          Sid      = "ListData"
          Effect   = "Allow"
          Action   = ["s3:ListBucket"]
          Resource = "arn:aws:s3:::${var.data_bucket}"
        },
        {
          Sid      = "WriteOwnPrefixes"
          Effect   = "Allow"
          Action   = ["s3:PutObject", "s3:AbortMultipartUpload"]
          Resource = [for prefix in each.value.write_prefixes : "arn:aws:s3:::${var.data_bucket}/sports/${prefix}*"]
        },
        {
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
      ],
      length(try(local.plane_create_only_prefixes[each.key], [])) > 0 ? [
        {
          # s3:if-none-match is the S3 conditional-write condition key (docs "Enforce conditional writes"): the
          # Null form is AWS's documented one (the header must be present), StringEquals pins its value to *.
          Sid      = "CreateOnlyOwnPrefixes"
          Effect   = "Allow"
          Action   = ["s3:PutObject"]
          Resource = [for prefix in try(local.plane_create_only_prefixes[each.key], []) : "arn:aws:s3:::${var.data_bucket}/sports/${prefix}*"]
          Condition = {
            StringEquals = { "s3:if-none-match" = "*" }
            Null         = { "s3:if-none-match" = "false" }
          }
        },
      ] : [],
      each.value.exec ? [
        {
          Sid    = "EcsExecChannels"
          Effect = "Allow"
          Action = [
            "ssmmessages:CreateControlChannel",
            "ssmmessages:CreateDataChannel",
            "ssmmessages:OpenControlChannel",
            "ssmmessages:OpenDataChannel",
          ]
          Resource = "*"
        },
      ] : [],
    )
  })
}

resource "aws_iam_role" "task_execution" {
  name = "pmbot-task-execution"

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

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
