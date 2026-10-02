# EP-035: the private history view the public status page cannot give (polymarket-bot docs/runbooks/ops.md). Only
# metrics that exist with Container Insights off (the shared cluster does not enable it): per-service CPU and memory
# utilization and tasks reporting (AWS/ECS), the shared cluster's reservation (every product: is there room for
# EP-034's research slot), job outcomes over days, the paper maker's pulse, the status writer, and one alarm widget.
# The page shows the live state; nothing here repeats it. No host CPU or burst-credit widget: the instance belongs to
# the platform (its ASG has a generated name and no output this stack reads). About $3 a month once the account has
# more than three dashboards.
#
# Every per-service dimension is this cluster and a pmbot-* service; there is no SEARCH() expression (it would read
# the whole account).

locals {
  # The five long-running services plus pmbot-status (not in local.services).
  dashboard_services = concat(keys(local.services), ["status"])

  # Every pmbot alarm of alarms.tf on this base (PR 2 is independent of PR 1: the status, data-stale and maker alarms
  # of EP-035 PR 1 are added to this list when that PR is merged). A new alarm shows up here by editing this one list. Unknown until the alarms
  # exist: a plan that creates them shows the body as known after apply.
  dashboard_alarm_arns = concat(
    [for alarm in aws_cloudwatch_metric_alarm.service_down : alarm.arn],
    [aws_cloudwatch_metric_alarm.daily_ingest_failed.arn],
    [aws_cloudwatch_metric_alarm.daily_ingest_missing.arn],
    aws_cloudwatch_metric_alarm.predictor_failed[*].arn,
    aws_cloudwatch_metric_alarm.predictor_stale[*].arn,
    [aws_cloudwatch_metric_alarm.maker_stale_predictions.arn],
    [aws_cloudwatch_metric_alarm.s3_put_forbidden.arn],
  )

  dashboard_service_metrics = {
    for metric in ["CPUUtilization", "MemoryUtilization"] : metric => [
      for service in local.dashboard_services :
      ["AWS/ECS", metric, "ClusterName", local.cluster_name, "ServiceName", "pmbot-${service}", { label = service }]
    ]
  }

  dashboard_widgets = [
    {
      type   = "metric"
      x      = 0
      y      = 0
      width  = 12
      height = 6
      properties = {
        title   = "CPU utilization per service (% of reserved CPU units; above 100 = spare host CPU)"
        view    = "timeSeries"
        region  = var.aws_region
        stat    = "Maximum"
        period  = 300
        metrics = local.dashboard_service_metrics["CPUUtilization"]
      }
    },
    {
      type   = "metric"
      x      = 12
      y      = 0
      width  = 12
      height = 6
      properties = {
        title   = "Memory utilization per service (% of the tasks' memory, AWS/ECS)"
        view    = "timeSeries"
        region  = var.aws_region
        stat    = "Maximum"
        period  = 300
        metrics = local.dashboard_service_metrics["MemoryUtilization"]
      }
    },
    {
      type   = "metric"
      x      = 0
      y      = 6
      width  = 12
      height = 6
      properties = {
        title  = "Tasks reporting per service (CPUUtilization samples per minute; 0 = no running task)"
        view   = "timeSeries"
        region = var.aws_region
        stat   = "SampleCount"
        period = 60
        metrics = [
          for service in local.dashboard_services :
          ["AWS/ECS", "CPUUtilization", "ClusterName", local.cluster_name, "ServiceName", "pmbot-${service}", { label = service }]
        ]
      }
    },
    {
      type   = "metric"
      x      = 12
      y      = 6
      width  = 12
      height = 6
      properties = {
        title  = "Shared cluster reservation (% of the one host, every product)"
        view   = "timeSeries"
        region = var.aws_region
        stat   = "Average"
        period = 300
        metrics = [
          ["AWS/ECS", "MemoryReservation", "ClusterName", local.cluster_name, { label = "memory" }],
          ["AWS/ECS", "CPUReservation", "ClusterName", local.cluster_name, { label = "cpu" }],
        ]
      }
    },
    {
      type   = "metric"
      x      = 0
      y      = 12
      width  = 12
      height = 6
      properties = {
        title  = "Scheduled jobs (runs per hour)"
        view   = "timeSeries"
        region = var.aws_region
        stat   = "Sum"
        period = 3600
        metrics = [
          ["pmbot", "PredictorOk", { label = "predictor ok" }],
          ["pmbot", "PredictorFailed", { label = "predictor failed" }],
          ["pmbot", "DailyIngestOk", { label = "daily ingest ok" }],
          ["pmbot", "DailyIngestFailed", { label = "daily ingest failed" }],
        ]
      }
    },
    {
      type   = "metric"
      x      = 12
      y      = 12
      width  = 12
      height = 6
      properties = {
        title  = "Paper maker (ticks left, critical and kill-switch events right)"
        view   = "timeSeries"
        region = var.aws_region
        stat   = "Sum"
        period = 300
        metrics = [
          ["pmbot", "MakerTicks", { label = "ticks" }],
          ["pmbot", "MakerCritical", { label = "critical", yAxis = "right" }],
          ["pmbot", "MakerKillSwitch", { label = "kill switch", yAxis = "right" }],
        ]
      }
    },
    {
      type   = "metric"
      x      = 0
      y      = 18
      width  = 24
      height = 6
      properties = {
        title  = "Status writer (publishes left, stale-tile events right)"
        view   = "timeSeries"
        region = var.aws_region
        stat   = "Sum"
        period = 300
        metrics = [
          ["pmbot", "StatusPublished", { label = "published" }],
          ["pmbot", "StatusTileStaleRecorder", { label = "recorder stale", yAxis = "right" }],
          ["pmbot", "StatusTileStaleXvenuePoller", { label = "xvenue-poller stale", yAxis = "right" }],
          ["pmbot", "StatusTileStaleRewardsPoll", { label = "rewards-poll stale", yAxis = "right" }],
        ]
      }
    },
    {
      type   = "alarm"
      x      = 0
      y      = 24
      width  = 24
      height = 8
      properties = {
        title  = "pmbot alarms"
        alarms = local.dashboard_alarm_arns
      }
    },
  ]
}

resource "aws_cloudwatch_dashboard" "pmbot" {
  count = var.dashboard_enabled ? 1 : 0

  dashboard_name = "pmbot"
  dashboard_body = jsonencode({ widgets = local.dashboard_widgets })
}

# Optional spend guard on pmbot's own resources. The account hosts every product, so the budget must filter on the
# Product=pmbot cost-allocation tag (an unfiltered budget would track everyone). That tag covers only what this stack
# tags (log groups, alarms, ECR, the site bucket and CloudFront, the scheduler, the task definitions): never the
# shared host, which is a platform resource, nor the data bucket created outside Terraform. Default none
# (budget_monthly_usd = 0): until the tag is activated in the billing console a tag-filtered budget tracks $0 and
# never fires. After activation set e.g. 25. AWS Budgets cannot publish to the platform-alerts topic (its policy has
# no budgets.amazonaws.com grant and platform/ is out of scope), so it mails budget_email: 80 % of the limit actual,
# 100 % forecast.
resource "aws_budgets_budget" "pmbot" {
  count = var.budget_monthly_usd > 0 ? 1 : 0

  name         = "pmbot-monthly"
  budget_type  = "COST"
  time_unit    = "MONTHLY"
  limit_amount = tostring(var.budget_monthly_usd)
  limit_unit   = "USD"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Product$pmbot"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }
}
