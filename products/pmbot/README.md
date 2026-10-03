# pmbot

The polymarket-bot sports stack (`OptimusFoundry/polymarket-bot`). **Paper trading only**: the maker's
task definition forces `LIVE_TRADING=0`, and no key, secret or `POLYMARKET_*` variable exists in this stack.

It runs on the **shared platform ECS cluster** (`ecs-cluster`, one t4g.2xlarge — see `platform/ecs.tf`) like
every other product. Applied by hand from a saved plan, like every other stack.

## What this stack owns

| Resource | Name |
|---|---|
| State | `s3://pmbot-terraform-state/state/terraform.tfstate` (S3 native locking) |
| ECR | `pmbot` — IMMUTABLE, `prevent_destroy`, keeps the 120 newest images |
| Services | `pmbot-recorder`, `pmbot-maker-paper`, `pmbot-ingame-capture`, `pmbot-xvenue-poller`, `pmbot-rewards-poll`, `pmbot-status` (parked at 0) |
| Schedules | `pmbot-daily-ingest` (06:00 America/New_York), `pmbot-predictor` (every 15 min), `pmbot-scoring` (09:00 America/New_York, polymarket-bot CH-012) |
| Research jobs | `pmbot-research` (EC2, one at a time) and `pmbot-research-fargate` (Fargate Spot, in parallel): task definitions only, no service and no schedule (polymarket-bot EP-034, CH-011); SG `pmbot-research-fargate`, SSM `/pmbot/research-fargate/network` |
| Task roles | `pmbot-task-{collect,model,paper,research}` (one per plane), `pmbot-status`, `pmbot-task-execution`, `pmbot-scheduler` |
| GitHub roles | `pmbot-github-ecr-push`, `pmbot-github-deploy`, `pmbot-github-research-run` (polymarket-bot `main`, OIDC) |
| Logs | `/ecs/pmbot/<family>`, 30 days |
| Alarms | `pmbot-<service>-not-running` ×5, daily-ingest failed/missing, predictor failed/stale, scoring failed/missing, maker stale predictions, S3 put forbidden, and the EP-035 per-plane alarms (section "Alarms by plane") — all to `platform-alerts` |
| Status site | `pmbot.protoapp.xyz`: bucket `pmbot-site-<account>` + CloudFront on the platform wildcard cert + Cloudflare record |
| Manifest | `/pmbot/manifest` |
| Dashboard and budget (EP-035) | CloudWatch dashboard `pmbot` (`dashboard_enabled`, default on) and an optional AWS Budget `pmbot-monthly` on the `Product=pmbot` tag (`budget_monthly_usd`, default 0 = none) |

Not managed here: the data bucket `polymarket-bot-data-339713122183` (created outside Terraform).

## How it differs from the other products, and why

- **No `modules/product`.** pmbot serves no API, and the module always creates an ALB target group and
  listener rule. The status site's bucket and distribution are built by hand in `status.tf`.
- **Its own task and deploy roles** instead of platform's `ecsTaskRole` and the admin GitHub role: each
  plane may write only its own S3 prefixes and never delete.
- **Stop-then-start deploys** (`deployment_minimum_healthy_percent = 0`): two recorders, or two makers on
  one data volume, must never run at once.
- **`/data` is a Docker volume per family** (`pmbot-<family>`, shared scope). It survives task restarts and
  redeploys, not a host replacement — the data is synced to S3 and the maker restores its journal on start.
  On the host it lives under `/var/lib/docker/volumes/pmbot-<family>/_data`.

## Deploys

polymarket-bot's `pmbot-deploy` workflow (as `pmbot-github-deploy`) registers every revision the services
and schedules run, swapping only the image SHA. Services ignore `task_definition` and schedules ignore
their target's task definition, so an app deploy leaves this stack's plan clean.

`var.image_tag` only seeds each family's first revision. A task-definition edit applied here reaches the
services only on the next `pmbot-deploy`:

    gh workflow run pmbot-deploy.yml --repo OptimusFoundry/polymarket-bot --ref main -f image_tag=<sha running now>

Sizes live in `local.task_sizes` (`services.tf`) and must equal polymarket-bot `sports/ops/sizing.py`
`SIZES`; its `check-tf` command parses that block, so keep one family per line. Plane write prefixes live
in `local.planes` (`iam.tf`).

## Research jobs (EP-034)

`research.tf`, the workflow role in `github.tf` and the research plane's ledger statement in `iam.tf`. Runbook:
polymarket-bot `docs/runbooks/research-jobs.md`.

- **Task definition only.** `pmbot-research` (container `research`, `<image_tag>-research`, role `pmbot-task-research`,
  `cpu` 512, `memory` 4096, **no `memoryReservation`**, its own volume `pmbot-research` at `/data`, `SPORTS_S3=rw`,
  `SPORTS_S3_QUEUE=research`, `SPORTS_LEDGER=s3`). No service, no schedule: polymarket-bot's `sports.research.run`
  starts it with `run-task --launch-type EC2`, refused at once (`RESOURCE:MEMORY`) when the shared host has no
  unreserved 4096 MiB. ECS counts the hard cap at placement, so a job never takes memory another task reserved, but
  while it runs it holds 4096 MiB that the predictor or another product's deploy may need: one job at a time.
  Log group `/ecs/pmbot/research` (30 days), stream `research/research/<task id>`.
- **Ledger.** The research role may `PutObject` `sports/ledger/records/*` only with `s3:if-none-match` = `*` (a create
  that fails when the key exists), keeps the `Deny` of `s3:Delete*`, and no longer writes `sports/ledger.jsonl`.
- **Workflow role.** `pmbot-github-research-run` (OIDC: `main` and the workflow file `pmbot-research.yml` on `main`,
  3 h sessions) may `ecs:RunTask` `pmbot-research` on `ecs-cluster`, `ecs:DescribeTasks` on the cluster's tasks,
  `iam:PassRole` the research and execution roles, and `logs:GetLogEvents` on `/ecs/pmbot/research`. Output
  `github_research_run_role_arn` = repository variable `PMBOT_RESEARCH_ROLE_ARN` in polymarket-bot.

## Parallel research jobs on Fargate (CH-011)

`research-fargate.tf`, the inline policy `run-research-fargate` in `github.tf`, and the cluster's capacity providers in
`platform/ecs.tf`. Runbook: polymarket-bot `docs/runbooks/research-jobs.md`.

- **Task definition** `pmbot-research-fargate`: Fargate, ARM64, 1 vCPU / 8 GiB, 50 GiB ephemeral storage at `/data`
  (no Docker volume), the same container `research`, environment, task role `pmbot-task-research`, execution role and
  log group `/ecs/pmbot/research` (stream `research/research/<task id>`) as `pmbot-research`.
- **Network:** `awsvpc` in the platform's public subnets with a public IP (no NAT), security group
  `pmbot-research-fargate` (no ingress, TCP 443 out). The launcher reads both from `/pmbot/research-fargate/network`.
- **Capacity:** `platform/ecs.tf` associates `FARGATE` and `FARGATE_SPOT` with `ecs-cluster`, with no default strategy.
  The launcher passes `FARGATE_SPOT` (default) or `FARGATE` explicitly.
- **Workflow role:** may also `ecs:RunTask` `pmbot-research-fargate` on `ecs-cluster`, `ecs:ListTasks` (the launcher's
  `RESEARCH_MAX_CONCURRENT` cap and `list`) and `ssm:GetParameter` on the network parameter.
- **Deploys:** pmbot-deploy must list the family as a job (polymarket-bot `ecs_deploy.JOBS`) to register revisions
  with the running image; until then the bootstrap revision cannot run jobs.

## Operating

- **Kill switch:** `aws ecs update-service --cluster ecs-cluster --service pmbot-<name> --desired-count 0`.
  Terraform ignores `desired_count`; scale back up with `--desired-count 1`.
- **Predictor / daily ingest / scoring off:** set `predictor_enabled` / `daily_ingest_enabled` / `scoring_enabled` to
  `false` and apply.
- **Status page:** `pmbot-status` builds `status.json` from the data bucket (`STATUS_SOURCE=s3`), not a
  local `/data`, because each family has its own volume. Scale it with
  `aws ecs update-service --cluster ecs-cluster --service pmbot-status --desired-count 1` (or `0`).
- **Task sizing:** polymarket-bot `sports.ops.sizing measure` reads Container Insights. Set
  `ecs_container_insights = true` in `platform` for the measurement window, then back to `false`.
- **Legacy `pmbot-task` role:** removed 2026-10-03 (polymarket-bot CHORE-017). Task-definition revisions from before
  the plane split still name it and no longer start; roll back no further than a per-plane revision.

## Status writer (EP-035)

- **Data.** `pmbot-status` mounts no data volume: with `STATUS_SOURCE=s3` it mirrors the few `sports/` prefixes it
  reads from the data bucket into a per-tick scratch directory (polymarket-bot `sports/ops/status_mirror.py`). It sees a
  source when that source uploads, so the page cannot show host-local upload-queue depth (`s3_queues` is always empty);
  the maker's kill switch and live journal do come through the mirror.
- **IAM.** `pmbot-status` may `PutObject` `status.json` (its only write), open ECS Exec channels, list `sports/*` and
  read `sports/live/maker/*` on the data bucket (the mirror), and make four read-only calls: `ecs:DescribeServices` on
  this cluster's `pmbot-*` services, `cloudwatch:GetMetricData` (`*`: no resource-level support),
  `cloudwatch:DescribeAlarms` (`*`: no resource-level permissions; names and states only) and, only while
  `status_cost_source = "ce"`, `ce:GetCostAndUsage` (`*`). A missing grant makes that page section show `error`; it
  never blanks the page.
- **Environment.** `STATUS_AWS=on`, `STATUS_COST_SOURCE=var.status_cost_source`, `STATUS_CLUSTER=local.cluster_name`
  (required by the writer, which has no cluster default).
- **Cost source** (`status_cost_source`). `estimate` (default): pmbot's share of the shared host by reserved memory at
  list price. `ce`: that share month to date plus Cost Explorer's actual for the `Product=pmbot`-tagged lines (CloudWatch,
  site bucket, CloudFront, ECR); the host is the platform's and never appears under the tag. `ce` needs the `Product`
  cost-allocation tag activated (Billing console; up to 24 h) and asks once a day at $0.01 a request. `off`: no panel.
- **Changing any of this** replaces `aws_ecs_task_definition.status` (a new revision); the service keeps its revision
  until the next `pmbot-deploy`. Expect `1 to add, 1 to change, 1 to destroy` when the role policy changes too.

## Alarms by plane (EP-035)

Every alarm notifies `local.alerts_topic_arn`, the platform's `platform-alerts` topic, on ALARM and on OK; its one email
subscription goes to the owner. pmbot creates no SNS topic. An unconfirmed subscription (`PendingConfirmation` in
`aws sns list-subscriptions-by-topic`) delivers nothing. Custom metrics are in namespace `pmbot`, from log metric
filters with quoted-term patterns on the task log groups (the containers log with structlog's console renderer, and a
quoted term matches the JSON renderer too). Runbook: polymarket-bot `docs/runbooks/ops.md`.

| Plane | Alarm | Fires when | Missing data | Exists |
|---|---|---|---|---|
| collect | `pmbot-recorder-not-running`, `pmbot-ingame-capture-not-running`, `pmbot-xvenue-poller-not-running`, `pmbot-rewards-poll-not-running` | no `AWS/ECS` `CPUUtilization` sample for 5 x 60 s (no running task) | breaching | always |
| collect | `pmbot-recorder-data-stale`, `pmbot-xvenue-poller-data-stale`, `pmbot-rewards-poll-data-stale` | the status writer logged `status_tile_stale tile=<name>` in each of 3 x 5 min (the tile is past its own stale limit plus 15 min) | notBreaching | `status_alarms_enabled` |
| model | `pmbot-daily-ingest-failed`, `pmbot-daily-ingest-missing` | `daily_ingest_failed` logged; no `daily_ingest_ok` for 26 h | notBreaching; breaching | always |
| model | `pmbot-predictor-failed`, `pmbot-predictor-stale` | `predictor_failed` logged; no `predictor_ok` for 4 x 15 min | notBreaching; breaching | `predictor_enabled` |
| model | `pmbot-scoring-failed`, `pmbot-scoring-missing` | `scoring_failed` logged; no `scoring_ok` for 26 h (polymarket-bot CH-012) | notBreaching; breaching | `scoring_enabled` |
| paper | `pmbot-maker-paper-not-running` | no running task for 5 x 60 s | breaching | always |
| paper | `pmbot-maker-stale-predictions` | a market refused as `stale_predictions` | notBreaching | always |
| paper | `pmbot-maker-paper-critical` | any event of `local.maker_critical_events` in 5 min (`tick_failed`, `journal_corrupt_engine_halted`, `engine_halted`, `post_unknown`, ...) | notBreaching | always |
| paper | `pmbot-maker-paper-kill-switch` | `kill_idle` or `kill_orders_remaining` in 5 min (the KILL file is on) | notBreaching | always |
| paper | `pmbot-maker-paper-no-ticks` | no `tick` event for 3 x 5 min | breaching | always |
| live | none yet | EP-033 mirrors the paper set on `maker-live` | | |
| research | none yet | EP-034 adds the research job's outcome alarms | | |
| ops | `pmbot-status-not-publishing` | no `status_published` for 3 x 5 min | breaching | `status_alarms_enabled` |
| any | `pmbot-s3-put-forbidden` | an `s3_put_forbidden` line in any task log | notBreaching | always |

- **`status_alarms_enabled`** (default `true` since 2026-10-02): set it `false` while `pmbot-status` is parked at
  desired 0, or the breaching `StatusPublished` alarm sits in ALARM. The filters behind both alarms are always on, so
  the metrics keep their history across a flip.
- **Scaling the maker to 0** (the kill-switch runbook) also trips `pmbot-maker-paper-not-running` and, after 15 minutes,
  `pmbot-maker-paper-no-ticks`: expected.
- **Not alarmed, on purpose:** `ingame-capture` staleness (it writes only during games) and the predictor tiles (the two
  predictor alarms cover them); the maker's loss cap (a journaled refusal, not a log event); `pmbot-status` in
  `service_down` (`pmbot-status-not-publishing` is stricter).
- **`tick` is a substring term:** it also matches `tick_failed` lines, which `pmbot-maker-paper-critical` reports anyway.
- **The event names live in polymarket-bot** (`sports/trading/run.py`, `engine.py`, `sports/ops/status_page.py`); a
  rename there blinds the matching filter silently. Re-check them whenever those files change.

## Dashboard and budget (EP-035)

`dashboard.tf`. Both are separable from the alarms and the status page: nothing else depends on them.

- **Dashboard `pmbot`** (`dashboard_enabled`, default `true`). Only what the public status page cannot show, and only
  metrics that exist with Container Insights off: per-service `AWS/ECS` CPU and memory utilization (percent of what the
  tasks reserve), tasks reporting per service (`CPUUtilization` samples, the not-running alarms' signal), the shared
  cluster's CPU/memory reservation (every product), scheduled-job outcomes per hour, the paper maker's ticks, critical
  and kill-switch events, the status writer's publishes and stale tiles, and one widget with every alarm of `alarms.tf`
  (add a new alarm to `local.dashboard_alarm_arns`). No host CPU or credit widget: the instance is the platform's.
- **Budget `pmbot-monthly`** (`budget_monthly_usd`, default `0` = none). A monthly COST budget filtered on the
  `Product=pmbot` cost-allocation tag (`TagKeyValue` = `user:Product$pmbot`), mailing `budget_email` at 80 % actual and
  100 % forecast. The account is shared, so the tag filter is what keeps other products out; it also means the shared
  host (a platform resource) and the untagged data bucket are not counted. Until the tag is activated (Billing console,
  Cost allocation tags: `Product`; data within 24 h) a tag-filtered budget tracks $0 and never fires: leave the limit at
  0, then set it (e.g. 25) by a PR and an owner apply.
- **Applying.** Like everything here, by the owner from a saved plan. With the alarms (EP-035 PR 1) already applied:
  `1 to add, 0 to change, 0 to destroy` (`2 to add` with a budget).
