# Liveness. AWS/ECS publishes a service's CPUUtilization every minute while at least one of its
# tasks runs and nothing when none does, so five minutes without a datapoint is "no task". Free,
# unlike Container Insights' RunningTaskCount, which the shared cluster does not enable.
resource "aws_cloudwatch_metric_alarm" "service_down" {
  for_each = local.services

  alarm_name          = "pmbot-${each.key}-not-running"
  alarm_description   = "pmbot-${each.key} has had no running task for 5 minutes."
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "SampleCount"
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 5

  # breaching: missing data here means "no task", the outage this alarm exists to catch.
  treat_missing_data = "breaching"

  alarm_actions = [local.alerts_topic_arn]
  ok_actions    = [local.alerts_topic_arn]

  dimensions = {
    ClusterName = local.cluster_name
    ServiceName = "pmbot-${each.key}"
  }
}

# Daily ingest outcome, from the two events the CLI logs. The pattern is a quoted
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

# Predictor. The CLI logs exactly one of predictor_ok / predictor_failed per run (an overlapping
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

# The paper maker (MAKER_PREDICTIONS_SOURCE=published) journals a refusal with detail
# stale_predictions for each due market whose published partition is missing, stale or bad.
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

# sports.core.s3sync parks an upload its plane's role was denied and logs s3_put_forbidden once per
# marker. One filter per task log group, one shared metric; silent until a plane role lacks a prefix
# its service writes.
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

# --- EP-035: alarms per plane (polymarket-bot docs/runbooks/ops.md) ---
#
# Log lines of every pmbot container are structlog's default ConsoleRenderer (no processor is configured in
# strategy-layer/sports, and colour is off without a TTY): `<time> [level] <event> <k=v ...>`, fields sorted by key.
# A quoted term therefore matches both that and the JSON renderer; `tile=<name>` is the console form of a field and
# several terms in one pattern are ANDed. A bare term matches as a substring, so a term must not occur inside the name of an
# event outside the list (checked 2026-10-02 against every log call in strategy-layer/sports/trading: the only
# containments, cancel_pass_failed and engine_halted, sit inside events that are themselves listed; `tick` is the
# documented exception below).
#
# Status plane (ops) and collect plane. The status writer (polymarket-bot sports/ops/status_page.py) logs
# `status_published` once per successful 60 s tick and `status_tile_stale tile=<name> state=<s> age_s=<n>` once per
# non-ok health tile per tick, so staleness reaches CloudWatch without giving the writer any write permission.
# The FILTERS are always on: the metrics then have history when the owner flips status_alarms_enabled, and the
# breaching StatusPublished alarm does not page once on the first evaluation. A parked writer logs nothing, so the
# metrics cost nothing then. Only the alarms are gated.
locals {
  # tile -> metric. Not ingame-capture (it writes only during games) and not the predictor tiles (EP-030's
  # pmbot-predictor-failed / -stale cover them).
  data_stale_tiles = {
    recorder        = { metric = "StatusTileStaleRecorder" }
    "xvenue-poller" = { metric = "StatusTileStaleXvenuePoller" }
    "rewards-poll"  = { metric = "StatusTileStaleRewardsPoll" }
  }

  # Paper maker events (polymarket-bot strategy-layer/sports/trading): run.py log.critical tick_failed (316),
  # tick_failures_exhausted_exiting (319), cancel_pass_failed (281); engine.py log.critical journal_corrupt_engine_halted
  # (129, 145), cancel_pass_failed_cancelling_known_orders (149); log.warning engine_halted (198, every tick while the
  # engine is halted, so the alarm stays up until the maker is fixed); log.error post_unknown (346), fill_unknown (373),
  # known_cancel_failed (221), unjournaled_cancel_failed (453), journal_append_failed (186),
  # kill_check_failed_treated_as_on (177). Not listed on purpose: per-market data errors that recur on a flaky API
  # (league_post_failed, market_inputs_failed, settle_inputs_failed, unknown_sweep_failed, book_unavailable_at_cancel,
  # tip_close_unavailable, cancel_failed, journal_salvage_failed), live_refused (the process exits: the
  # not-running alarm fires) and stopped_orders_left_resting (a deliberate --keep-orders stop).
  maker_critical_events = [
    "tick_failed",
    "tick_failures_exhausted_exiting",
    "cancel_pass_failed",
    "cancel_pass_failed_cancelling_known_orders",
    "journal_corrupt_engine_halted",
    "engine_halted",
    "post_unknown",
    "fill_unknown",
    "known_cancel_failed",
    "unjournaled_cancel_failed",
    "journal_append_failed",
    "kill_check_failed_treated_as_on",
  ]
}

resource "aws_cloudwatch_log_metric_filter" "status_published" {
  name           = "pmbot-status-published"
  log_group_name = aws_cloudwatch_log_group.status.name
  pattern        = "\"status_published\""

  metric_transformation {
    name      = "StatusPublished"
    namespace = "pmbot"
    value     = "1"
  }
}

resource "aws_cloudwatch_log_metric_filter" "tile_stale" {
  for_each = local.data_stale_tiles

  name           = "pmbot-status-tile-stale-${each.key}"
  log_group_name = aws_cloudwatch_log_group.status.name
  pattern        = "\"status_tile_stale\" \"tile=${each.key}\""

  metric_transformation {
    name      = each.value.metric
    namespace = "pmbot"
    value     = "1"
  }
}

# No status_published for three 5-minute periods, absence counted as breaching: the writer is down, wedged or cannot
# publish (status_publish_failed does not count). A service that is down at desired 0 is parked on purpose, hence the
# gate (default false until Rollout E4); pmbot-status is not in local.services, so service_down does not cover it.
resource "aws_cloudwatch_metric_alarm" "status_not_publishing" {
  count = var.status_alarms_enabled ? 1 : 0

  alarm_name          = "pmbot-status-not-publishing"
  alarm_description   = "pmbot-status has not logged status_published for 15 minutes (3 x 5 minutes): the status page is going stale. Runbook: docs/runbooks/ops.md."
  namespace           = "pmbot"
  metric_name         = "StatusPublished"
  statistic           = "Sum"
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  treat_missing_data  = "breaching"

  alarm_actions = [local.alerts_topic_arn]
  ok_actions    = [local.alerts_topic_arn]
}

# The writer logged status_tile_stale for this tile on every tick of three consecutive 5-minute periods: the tile is
# past its own stale limit (recorder 15 min, xvenue-poller 75 min in the S3 view, which sees its hourly upload,
# rewards-poll 2.5 h) plus 15 minutes. notBreaching: when the writer itself is down there is no event, and
# pmbot-status-not-publishing says so.
resource "aws_cloudwatch_metric_alarm" "data_stale" {
  for_each = var.status_alarms_enabled ? local.data_stale_tiles : {}

  alarm_name          = "pmbot-${each.key}-data-stale"
  alarm_description   = "The status page reports ${each.key} data stale (or missing) for 15 minutes beyond its own limit. Runbook: docs/runbooks/ops.md."
  namespace           = "pmbot"
  metric_name         = each.value.metric
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  treat_missing_data  = "notBreaching"

  alarm_actions = [local.alerts_topic_arn]
  ok_actions    = [local.alerts_topic_arn]
}

# Paper plane: maker-paper. Always on, like service_down: the maker runs at desired 1. Scaling it to 0 on purpose (the
# kill-switch runbook) also trips pmbot-maker-paper-no-ticks after 15 minutes: expected.
resource "aws_cloudwatch_log_metric_filter" "maker_critical" {
  name           = "pmbot-maker-paper-critical"
  log_group_name = aws_cloudwatch_log_group.svc["maker-paper"].name
  pattern        = join(" ", [for event in local.maker_critical_events : "?\"${event}\""])

  metric_transformation {
    name      = "MakerCritical"
    namespace = "pmbot"
    value     = "1"
  }
}

resource "aws_cloudwatch_log_metric_filter" "maker_kill_switch" {
  name           = "pmbot-maker-paper-kill-switch"
  log_group_name = aws_cloudwatch_log_group.svc["maker-paper"].name
  pattern        = "?\"kill_idle\" ?\"kill_orders_remaining\""

  metric_transformation {
    name      = "MakerKillSwitch"
    namespace = "pmbot"
    value     = "1"
  }
}

# One event per 20 s tick (trading/run.py TICK_S, `tick`); the bare term also matches tick_failed lines, which are
# critical anyway. Three per minute is far above one event per 15 minutes.
resource "aws_cloudwatch_log_metric_filter" "maker_ticks" {
  name           = "pmbot-maker-paper-ticks"
  log_group_name = aws_cloudwatch_log_group.svc["maker-paper"].name
  pattern        = "\"tick\""

  metric_transformation {
    name      = "MakerTicks"
    namespace = "pmbot"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "maker_critical" {
  alarm_name          = "pmbot-maker-paper-critical"
  alarm_description   = "The paper maker logged a critical or error event (journal, cancel or order handling; see local.maker_critical_events). Runbook: docs/runbooks/ops.md."
  namespace           = "pmbot"
  metric_name         = "MakerCritical"
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  period              = 300
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = [local.alerts_topic_arn]
  ok_actions    = [local.alerts_topic_arn]
}

# kill_idle (nothing rests, posting nothing) or kill_orders_remaining (cancel-only ticks continue): the KILL file is
# on. Expected during a deliberate halt; the OK mail says it was lifted.
resource "aws_cloudwatch_metric_alarm" "maker_kill_switch" {
  alarm_name          = "pmbot-maker-paper-kill-switch"
  alarm_description   = "The paper maker's kill switch is on (kill_idle / kill_orders_remaining): it posts nothing. Runbook: docs/runbooks/ops.md."
  namespace           = "pmbot"
  metric_name         = "MakerKillSwitch"
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  period              = 300
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = [local.alerts_topic_arn]
  ok_actions    = [local.alerts_topic_arn]
}

# No tick event for three 5-minute periods, absence counted as breaching: the loop is wedged or the task is not
# running (pmbot-maker-paper-not-running also fires in that case).
resource "aws_cloudwatch_metric_alarm" "maker_ticks" {
  alarm_name          = "pmbot-maker-paper-no-ticks"
  alarm_description   = "The paper maker logged no tick for 15 minutes (3 x 5 minutes; a tick is every 20 seconds). Runbook: docs/runbooks/ops.md."
  namespace           = "pmbot"
  metric_name         = "MakerTicks"
  statistic           = "Sum"
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  treat_missing_data  = "breaching"

  alarm_actions = [local.alerts_topic_arn]
  ok_actions    = [local.alerts_topic_arn]
}
