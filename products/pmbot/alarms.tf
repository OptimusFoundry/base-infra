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

# Predictor (EP-030). The CLI logs exactly one of predictor_ok / predictor_failed per run (an overlapping
# run logs neither). Quoted-term patterns and no default_value, as for the daily ingest.
resource "aws_cloudwatch_log_metric_filter" "predictor_ok" {
  name           = "pmbot-predictor-ok"
  log_group_name = aws_cloudwatch_log_group.svc["predictor"].name
  pattern        = "\"predictor_ok\""

  metric_transformation {
    name      = "PredictorOk"
    namespace = "pmbot"
    value     = "1"
  }
}

resource "aws_cloudwatch_log_metric_filter" "predictor_failed" {
  name           = "pmbot-predictor-failed"
  log_group_name = aws_cloudwatch_log_group.svc["predictor"].name
  pattern        = "\"predictor_failed\""

  metric_transformation {
    name      = "PredictorFailed"
    namespace = "pmbot"
    value     = "1"
  }
}

# The paper maker, with MAKER_PREDICTIONS_SOURCE=published, journals a refusal with detail
# stale_predictions for each due market whose partition is missing, stale or bad. Zero events while the
# source is `inline` (the default), so this alarm is quiet until the flag flips.
resource "aws_cloudwatch_log_metric_filter" "maker_stale_predictions" {
  name           = "pmbot-maker-stale-predictions"
  log_group_name = aws_cloudwatch_log_group.svc["maker-paper"].name
  pattern        = "\"stale_predictions\""

  metric_transformation {
    name      = "MakerStalePredictions"
    namespace = "pmbot"
    value     = "1"
  }
}

# The two predictor alarms exist only while the schedule is enabled: a disabled schedule logs nothing, and
# a staleness alarm on missing data would sit in ALARM from the day it is created.
resource "aws_cloudwatch_metric_alarm" "predictor_failed" {
  count = var.predictor_enabled ? 1 : 0

  alarm_name          = "pmbot-predictor-failed"
  alarm_description   = "The pmbot predictor logged predictor_failed (a league failed to publish). Runbook: docs/runbooks/predictor.md."
  namespace           = "pmbot"
  metric_name         = "PredictorFailed"
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  period              = 900
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = [local.alerts_topic_arn]
  ok_actions    = [local.alerts_topic_arn]
}

# No success for four 15-minute periods, absence counted as breaching: this catches a schedule that never
# ran, a task that could not start, and a run that always overlaps. Expect one transient ALARM mail within
# the first hour after enabling (missing data before the first run), the same as daily_ingest_missing.
resource "aws_cloudwatch_metric_alarm" "predictor_stale" {
  count = var.predictor_enabled ? 1 : 0

  alarm_name          = "pmbot-predictor-stale"
  alarm_description   = "No pmbot predictor success in the last hour (4 x 15 minutes). Published predictions go stale at 45 minutes."
  namespace           = "pmbot"
  metric_name         = "PredictorOk"
  statistic           = "Sum"
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  period              = 900
  evaluation_periods  = 4
  datapoints_to_alarm = 4
  treat_missing_data  = "breaching"

  alarm_actions = [local.alerts_topic_arn]
  ok_actions    = [local.alerts_topic_arn]
}

# The maker refused due markets as stale_predictions in the last five minutes. Silence is fine.
resource "aws_cloudwatch_metric_alarm" "maker_stale_predictions" {
  alarm_name          = "pmbot-maker-stale-predictions"
  alarm_description   = "The paper maker refused a market as stale_predictions (published predictions missing, stale or bad). Runbook: docs/runbooks/predictor.md."
  namespace           = "pmbot"
  metric_name         = "MakerStalePredictions"
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  period              = 300
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = [local.alerts_topic_arn]
  ok_actions    = [local.alerts_topic_arn]
}

# EP-031: sports.core.s3sync parks an upload marker its plane's role was denied and logs s3_put_forbidden once
# per marker (core/s3sync.py S3Forbidden). One filter per task log group, one shared metric. Always on: it is
# silent until a plane role lacks a prefix its service writes, and that is exactly when to hear about it.
resource "aws_cloudwatch_log_metric_filter" "s3_put_forbidden" {
  for_each = local.all_tasks

  name           = "pmbot-s3-put-forbidden-${each.key}"
  log_group_name = aws_cloudwatch_log_group.svc[each.key].name
  pattern        = "\"s3_put_forbidden\""

  metric_transformation {
    name      = "S3PutForbidden"
    namespace = "pmbot"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "s3_put_forbidden" {
  alarm_name          = "pmbot-s3-put-forbidden"
  alarm_description   = "A pmbot task was denied an S3 upload (s3_put_forbidden): its plane role lacks the prefix. The marker is parked under .s3-queue/<plane>/forbidden/. Runbook: docs/runbooks/images-iam.md."
  namespace           = "pmbot"
  metric_name         = "S3PutForbidden"
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  period              = 300
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = [local.alerts_topic_arn]
  ok_actions    = [local.alerts_topic_arn]
}
