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
| Schedules | `pmbot-daily-ingest` (06:00 America/New_York), `pmbot-predictor` (every 15 min) |
| Research jobs | `pmbot-research`: a task definition only, no service and no schedule (polymarket-bot EP-034) |
| Task roles | `pmbot-task-{collect,model,paper,research}` (one per plane), `pmbot-task` (legacy), `pmbot-status`, `pmbot-task-execution`, `pmbot-scheduler` |
| GitHub roles | `pmbot-github-ecr-push`, `pmbot-github-deploy`, `pmbot-github-research-run` (polymarket-bot `main`, OIDC) |
| Logs | `/ecs/pmbot/<family>`, 30 days |
| Alarms | `pmbot-<service>-not-running` ×5, daily-ingest failed/missing, predictor failed/stale, maker stale predictions, S3 put forbidden — all to `platform-alerts` |
| Status site | `pmbot.protoapp.xyz`: bucket `pmbot-site-<account>` + CloudFront on the platform wildcard cert + Cloudflare record |
| Manifest | `/pmbot/manifest` |

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

## Operating

- **Kill switch:** `aws ecs update-service --cluster ecs-cluster --service pmbot-<name> --desired-count 0`.
  Terraform ignores `desired_count`; scale back up with `--desired-count 1`.
- **Predictor / daily ingest off:** set `predictor_enabled` / `daily_ingest_enabled` to `false` and apply.
- **Status page:** `pmbot-status` builds `status.json` from the data bucket (`STATUS_SOURCE=s3`), not a
  local `/data`, because each family has its own volume. Scale it with
  `aws ecs update-service --cluster ecs-cluster --service pmbot-status --desired-count 1` (or `0`).
- **Task sizing:** polymarket-bot `sports.ops.sizing measure` reads Container Insights. Set
  `ecs_container_insights = true` in `platform` for the measurement window, then back to `false`.
- **Legacy `pmbot-task` role:** kept so a rollback to a pre-plane-split revision still runs. Remove it from
  config (and from the two PassRole lists) when that rollback is no longer wanted.
