# Liveness: the dedicated pmbot cluster has Container Insights enabled, so RunningTaskCount
# exists per service. Below 1 for five one-minute periods in a row is "no task".
resource "aws_cloudwatch_metric_alarm" "service_down" {
  for_each = local.services

  alarm_name          = "pmbot-${each.key}-not-running"
  alarm_description   = "pmbot-${each.key} has had no running task for 5 minutes."
  namespace           = "ECS/ContainerInsights"
  metric_name         = "RunningTaskCount"
  statistic           = "Average"
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 5

  # breaching, not notBreaching: a stopped service can stop reporting, and missing data here
  # means "no task", the outage this alarm exists to catch.
  treat_missing_data = "breaching"

  alarm_actions = [local.alerts_topic_arn]
  ok_actions    = [local.alerts_topic_arn]

  dimensions = {
    ClusterName = local.cluster_name
    ServiceName = "pmbot-${each.key}"
  }
}

# Daily ingest outcome, from the two events the CLI logs (T7). The pattern is a quoted
# term: it matches both the console and the JSON structlog renderers. default_value is
# left unset on purpose, so a day without the event is missing data, not a zero.
resource "aws_cloudwatch_log_metric_filter" "daily_ingest_ok" {
  name           = "pmbot-daily-ingest-ok"
  log_group_name = aws_cloudwatch_log_group.svc["daily-ingest"].name
  pattern        = "\"daily_ingest_ok\""

  metric_transformation {
    name      = "DailyIngestOk"
    namespace = "pmbot"
    value     = "1"
  }
}

resource "aws_cloudwatch_log_metric_filter" "daily_ingest_failed" {
  name           = "pmbot-daily-ingest-failed"
  log_group_name = aws_cloudwatch_log_group.svc["daily-ingest"].name
  pattern        = "\"daily_ingest_failed\""

  metric_transformation {
    name      = "DailyIngestFailed"
    namespace = "pmbot"
    value     = "1"
  }
}

# A failure alarms within five minutes. Silence is fine here (notBreaching), so the alarm
# returns to OK by itself after the next quiet period.
resource "aws_cloudwatch_metric_alarm" "daily_ingest_failed" {
  alarm_name          = "pmbot-daily-ingest-failed"
  alarm_description   = "The pmbot daily ingest logged daily_ingest_failed. Re-run it from the runbook."
  namespace           = "pmbot"
  metric_name         = "DailyIngestFailed"
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  period              = 300
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = [local.alerts_topic_arn]
  ok_actions    = [local.alerts_topic_arn]
}

# No success for 26 hourly periods, absence counted as breaching: this catches a schedule
# that never ran (or a task that could not start), which logs nothing at all.
resource "aws_cloudwatch_metric_alarm" "daily_ingest_missing" {
  alarm_name          = "pmbot-daily-ingest-missing"
  alarm_description   = "No pmbot daily ingest success in the last 26 hours."
  namespace           = "pmbot"
  metric_name         = "DailyIngestOk"
  statistic           = "Sum"
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  period              = 3600
  evaluation_periods  = 26
  treat_missing_data  = "breaching"

  alarm_actions = [local.alerts_topic_arn]
  ok_actions    = [local.alerts_topic_arn]
}
