# pmbot

The polymarket-bot sports stack (`OptimusFoundry/polymarket-bot`, formerly `SAVentures/polymarket-bot`) on AWS.
One linux/arm64 image runs the recorder, the paper maker, three research collectors and a daily ingest
as ECS tasks on a dedicated `t4g.xlarge` in a dedicated `pmbot` ECS cluster. The plan is CH-007 in the
polymarket-bot repo (`docs/superpowers/plans/`), the change brief is `docs/briefs/cloud-deploy.md` and the
runbook is `docs/runbooks/cloud-deploy.md`.

**Paper only.** The maker's task definition forces `LIVE_TRADING=0` and `LIVE_LEAGUES=NBA,NHL`. No key,
no secret and no `POLYMARKET_*` variable exists anywhere in this stack.

## What this stack owns

| Resource | Name |
|---|---|
| State | `s3://pmbot-terraform-state/state/terraform.tfstate` (created by hand, versioned) |
| ECS cluster | `pmbot` (Container Insights enabled) |
| Capacity provider | `pmbot` (backed by the pmbot ASG, managed scaling and termination protection off), default strategy weight 1, base 1 |
| ECR repository | `pmbot` (IMMUTABLE, scan on push, keeps the 120 newest images, about 30 pushes of four images, EP-031) |
| GitHub push role | `pmbot-github-ecr-push` (push to `pmbot` only, trusted for `main` of `var.github_repo`) |
| GitHub CD roles | `pmbot-github-deploy` (polymarket-bot `main`: ECS deploy only, including re-pointing the daily-ingest and predictor schedules), `pmbot-github-terraform` (base-infra `main`: plan and apply this stack), `pmbot-github-terraform-plan` (base-infra PRs: read-only plan) |
| Instance role / profile / SG | `pmbot-ecs-instance` (no ingress, all egress, no key pair) |
| Launch template + ASG | `pmbot-ecs-*`, exactly 1 instance, 100 GB encrypted gp3, IMDSv2 hop limit 1 |
| Task / execution / scheduler roles | `pmbot-task` (legacy, EP-031), `pmbot-task-collect`, `pmbot-task-model`, `pmbot-task-paper`, `pmbot-task-research` (one per plane), `pmbot-task-execution`, `pmbot-scheduler` |
| Log groups | `/ecs/pmbot/<name>` for the 7 tasks, 30 days |
| Task definitions | `pmbot-<name>` x 7 (bridge, EC2, arm64) |
| Services | `pmbot-recorder`, `pmbot-maker-paper`, `pmbot-ingame-capture`, `pmbot-xvenue-poller`, `pmbot-rewards-poll` |
| Schedules | `pmbot-daily-ingest` (06:00 America/New_York) and `pmbot-predictor` (every 15 minutes, ships DISABLED, EP-030), one attempt each |
| Alarms | 5 x `pmbot-<name>-not-running`, `pmbot-daily-ingest-failed`, `pmbot-daily-ingest-missing`, `pmbot-maker-stale-predictions`, and `pmbot-predictor-failed` and `pmbot-predictor-stale` (only while `predictor_enabled`), and `pmbot-s3-put-forbidden` (EP-031), to `platform-alerts` |
| Status site (CH-009) | `pmbot-site-<account>` bucket (private: OAC only, public access blocked, TLS only), CloudFront distribution for `pmbot.protoapp.xyz` on the platform wildcard certificate; DNS record in `products/pmbot/dns` |
| Status service (CH-009) | `pmbot-status` (task definition, service created at desired 0, log group `/ecs/pmbot/status`, task role `pmbot-status`: `s3:PutObject` on `status.json` only) |

`platform` is read through `terraform_remote_state` for the VPC, the public subnets and the `platform-alerts`
topic only. The shared `ecs-cluster` is never read or changed, and nothing in `platform/` or another product
changes: a full plan from an empty state was 47 creates before EP-030, 54 after it (56 with `predictor_enabled`) and is 70 after EP-031 (72 with `predictor_enabled`), all pmbot-named, and no update, replace or destroy.

## Topology (dedicated cluster, owner decision D1 = b)

- pmbot has its own ECS cluster, so no other product's task can land on the pmbot instance. The instance joins it
  by user data (`ECS_CLUSTER=pmbot`) and still registers the attribute `pmbot=dedicated`; every task definition,
  service and the schedule keep the `memberOf(attribute:pmbot == dedicated)` constraint as belt and braces.
- Services and the scheduled task place through the `pmbot` capacity provider strategy, not `launch_type`.
- The instance sits in a public subnet with a public IPv4 because the platform has an internet gateway and no
  NAT. The security group has no inbound rule; the only way onto the host is Session Manager.
- `/data/<family>` is a host directory per task on the root volume (owned by uid 10001, created by user data, EP-032), and every
  task mounts its own at `/data` in the container. The recorder, the collectors and the maker write there, and
  `sports.core.s3sync` uploads to `s3://polymarket-bot-data-339713122183`. S3 is the only channel between services.
- Services deploy stop-then-start (`deployment_minimum_healthy_percent = 0`, `maximum = 100`), so the old task
  gets SIGTERM and 120 s before the new one starts. Two recorders, or two makers on one `/data`, never run at once.
- Images are pinned by git SHA, but Terraform no longer deploys them (CH-008). polymarket-bot's `pmbot-deploy`
  workflow registers every revision the services and the schedule run. `aws_ecs_service.svc` ignores
  `task_definition` and the schedule ignores its target's `task_definition_arn`, so a plan after an app deploy is
  clean. `var.image_tag` only seeds a family's first revision (and, since EP-031, names the SHA whose `-<target>` images
  the families run). Changing it replaces every task definition with a new revision and moves nothing running: bump it only
  to a SHA whose five tags exist in ECR.
- Liveness alarms use `ECS/ContainerInsights` `RunningTaskCount` (`ClusterName = pmbot`), below 1 for 5 x 60 s,
  missing data counted as breaching.

## Continuous delivery (CH-008, no approval gate)

| What | Trigger | Role (GitHub OIDC, no secrets) | Does |
|---|---|---|---|
| App deploy | polymarket-bot `pmbot-image` succeeds on `main` (`pmbot-deploy.yml`, `workflow_run`), or a manual dispatch with an image tag | `pmbot-github-deploy` | a new revision of each of the 7 families (`pmbot-predictor` is skipped while it does not exist) with the image swapped and `PMBOT_GIT_SHA` set, `update-service` x5, wait until stable, re-point both schedules; rolls the services back on failure |
| Plan | base-infra PR touching `products/pmbot/**` (`.github/workflows/pmbot-terraform.yml`, job `plan`) | `pmbot-github-terraform-plan` (read-only; plans with `-lock=false`) | `fmt -check`, `validate`, `plan`, guard preview, PR comment |
| Apply | push to base-infra `main` touching `products/pmbot/**` (job `apply`) | `pmbot-github-terraform` | `plan -out`, `ci/plan_guard.py`, `apply` of that saved plan |

- **Scope.** CI plans and applies only `products/pmbot`. Three things keep it there: the workflow's path filters, its
  `working-directory`, and the roles' permissions. The roles can touch pmbot-named or `Product=pmbot`-tagged
  resources, objects in `pmbot-terraform-state`, and read only the platform state object.
- **The guard** (`ci/plan_guard.py`) refuses, so nothing is applied and the run fails:
  - any delete or replace of the cluster, its capacity provider and provider list, a service, the ASG, the launch
    template, the ECR repository, an IAM role or instance profile, a log group or a bucket;
  - any change to a `github_*` role or policy (CD never edits its own permissions);
  - any task definition gaining a `LIVE_ENABLE_*` or `POLYMARKET_*` variable or secret, or `LIVE_TRADING` other
    than `0`;
  - a task role's inline policy (`pmbot-task-<plane>`) that grants a write outside the plane's S3 prefixes, a wildcard
    action, any action outside `s3:GetObject`, `s3:ListBucket`, `s3:PutObject`, `s3:AbortMultipartUpload` and the
    `ssmmessages` channels, any SSM parameter access (only a future `pmbot-task-live` may read `/pmbot/live/*`), or that
    lacks an unconditional `Deny` of `s3:Delete*` on the bucket and its objects; a managed policy attached to a task
    role; and a change to the legacy `pmbot-task` policy that adds or alters a statement (it may only shrink).

  Creates and in-place updates pass. Tests: `python3 -m unittest discover -s products/pmbot/ci -p "test_*.py" -v`.
- **No tfvars.** Every value is a default in `variables.tf`, so a local plan equals CI's. Change a value by PR.
- **Locking.** The backend uses S3 native locking (`use_lockfile = true`, `state/terraform.tfstate.tflock`).
- **Task-definition edits.** An edit applied here does not reach the services until polymarket-bot's
  `pmbot-deploy` runs, because the services ignore `task_definition`. The guard's report lists such edits. Roll one out
  with:

      gh workflow run pmbot-deploy.yml --repo OptimusFoundry/polymarket-bot --ref main -f image_tag=<sha running now>

- **AMI drift** (the SSM recommended-image pointer) shows up as an in-place launch template and ASG update in the
  next plan, and is applied on the next merge. It never replaces the running instance (no `instance_refresh`).
- **Pause CD:** `gh workflow disable pmbot-terraform.yml --repo OptimusFoundry/base-infra`, or the same for
  `pmbot-deploy.yml` in polymarket-bot.

## Predictor (EP-030)

`pmbot-predictor` is an EventBridge-scheduled ECS task (`cron(0/15 * * * ? *)`, America/New_York, one attempt) that
runs `python -m sports.models.predictor.run publish`. It writes `predictions/<league>/<date>/<offset>/` to the data
bucket through the shared task role (`DataObjects` already allows `s3:PutObject` on the bucket; the `Deny` on
`s3:DeleteObject*` stays). Plan: polymarket-bot EP-030; runbook: `docs/runbooks/predictor.md` there.

- **Ships disabled.** `var.predictor_enabled` (default `false`) sets the schedule's state and creates the two predictor
  alarms (`pmbot-predictor-failed`, `pmbot-predictor-stale`). Enable it by a PR that changes the default to `true`, after
  one verified manual run. Disable it the same way. Expect one transient `pmbot-predictor-stale` ALARM mail in the first
  hour after enabling (missing data counts as breaching until the first run reports).
- **Size.** 1024 CPU units, 2048 MiB reservation, 4096 MiB limit (the spec size) since the `t4g.xlarge` (EP-032); every size comes
  from `local.task_sizes`.
- **Environment.** `PREDICTOR_LEAGUES=NBA,NHL` plus the common contract. No `LIVE_*`, no `POLYMARKET_*`, no secret.
  `PMBOT_GIT_SHA` (the published `model_version`) is added by `pmbot-deploy`, never here.
- **First run needs a deploy.** The Terraform-registered revision carries the bootstrap image, which has no predictor
  code. Dispatch `pmbot-deploy` with the running SHA once after the apply (it registers a revision with the current image
  and re-points the schedule), then run the task by hand and read `/ecs/pmbot/predictor`. This is the same rule as any
  task-definition edit (see Continuous delivery).
- **Flag flip.** The maker reads `MAKER_PREDICTIONS_SOURCE` (`inline`, the default when absent, or `published`). It is set
  in `local.maker_env` in `services.tf`. Changing it edits the `maker-paper` task definition, so it needs a `pmbot-deploy`
  dispatch to reach the service.
- **Deploy role.** `pmbot-github-deploy` may `scheduler:GetSchedule` and `UpdateSchedule` on `pmbot-predictor`
  (statement `RepointThePredictorSchedule` in `github-cd.tf`). `plan_guard.py` refuses CD changes to that role, so the
  statement was applied by the owner before the predictor resources were merged.

## Per-family data dirs, sizes and the research slot (EP-032)

Spec: polymarket-bot `docs/superpowers/specs/2026-10-01-pmbot-service-architecture-design.md` sections 6 and 8; runbook:
`docs/runbooks/data-plane-compute.md` there (rollout order, soak, OOM drill).

- **Data dirs.** Every task definition mounts host `/data/<family>` at `/data` (`volume.host_path`; the container path and
  `SPORTS_DATA_ROOT=/data` are unchanged). The dirs are created by the launch template's user data (owner 10001, `compute.tf`
  `local.data_families`), so **apply this only after the instance was replaced by the t4g.xlarge launch template**: on a host without the
  dirs Docker creates them as root and the services could not write. Host dirs survive task restarts and redeploys, not an instance
  replacement (the data is in S3; the maker restores its journal on start).
- **Sizes.** `local.task_sizes` holds `cpu`, `memory_reservation` (what the scheduler counts) and `memory` (the hard cap; exceeding it
  kills that container alone) per family, one line each. It must equal polymarket-bot `sports/ops/sizing.py` `SIZES`
  (`python -m sports.ops.sizing check-tf products/pmbot/services.tf` from `strategy-layer/`, exit 0) and `ci/test_services_sizes.py` pins the
  same table. Reservations total 7,680 MiB / 3,200 CPU units with `maker-live` (6,656 / 2,688 without) of the host's about
  15,200 MiB / 4,096.
- **Research slot.** `local.research_slot` (cpu 512, hard cap 4096, **no reservation**) is the size EP-034's research job will use: with no
  reservation it is placed only into memory nothing has reserved, and its CPU weight is half the predictor's. A container's hard `memory` is
  a cgroup limit, so a runaway job is OOM-killed alone (exit 137), never a neighbour. No task definition exists yet.
- **Environment.** `SPORTS_CACHE_PRUNE` (recorder `recorder/=7`, the three collectors `collectors/=7`, predictor and maker-paper
  `predictions/=3`; none on daily-ingest) lets a family's drainer delete S3-verified files older than N days;
  `DAILY_INGEST_REQUIRE_DRAINED=1` on daily-ingest fails its verdict if an upload is still queued.
- **Status page unchanged.** `aws_ecs_task_definition.status` (CH-009, `status.tf`) keeps its own literal size and its bare `/data`
  read-only mount; it is not in `local.task_sizes` and has no per-family dir. Its 64 CPU units / 192 MiB reservation are not in the totals above.
- **Applying this** replaces the 7 task definitions (`7 to add, 0 to change, 7 to destroy`); no service or schedule moves until
  `pmbot-deploy` runs. Dispatch it only after the owner's steps in the runbook (maker flushed, instance swapped).

## Per-plane task roles (EP-031)

Spec: polymarket-bot `docs/superpowers/specs/2026-10-01-pmbot-service-architecture-design.md` section 7; runbook:
`docs/runbooks/images-iam.md` there. Four roles, one per plane, defined by `local.planes` in `iam.tf`:

| Role | Plane | Writes (key prefixes under `sports/`) | ECS Exec |
|---|---|---|---|
| `pmbot-task-collect` | recorder, ingame-capture, xvenue-poller, rewards-poll | `recorder/`, `collectors/` | yes |
| `pmbot-task-model` | daily-ingest, predictor | `nba/`, `nhl/` (tables, raw, injury_parsed), `predictions/`, `recorder/nba_injury/` (daily-ingest runs the injury fetcher) | yes |
| `pmbot-task-paper` | maker-paper | `live/maker/journal.paper.*`, `live/prices/`, `live/tape/` (settle caches), `nba/injury_parsed/` (inline path's parse cache, until CHORE-015) | yes |
| `pmbot-task-research` | on-demand research jobs (none yet) | `experiments/`, `panel/`, `gamma/`, `prices/`, `pretrades/`, `tape/`, `hist/`, the four league dirs, `collectors/xvenue/`, `ledger.jsonl` | no |

Every role reads `sports/*` (`s3:GetObject`) and lists the bucket, writes only `PutObject` and `AbortMultipartUpload` on
object ARNs under its own prefixes, has an explicit `Deny` of `s3:Delete*`, `s3:PutBucket*` and
`s3:PutLifecycleConfiguration` on the bucket and its objects, and has **no** SSM parameter access (`EcsExecChannels` is the
`ssmmessages` debug channel, not parameters). The execution role stays shared. The legacy `pmbot-task` role stays: a
revision registered before the split, and a rollback to one, still run as it. It lost its SSM parameter statement; delete
the role by hand after two weeks on the plane roles (the guard refuses deleting an `aws_iam_role`).

- **Images are per target (EP-031).** CI pushes `<sha>-collect`, `<sha>-model`, `<sha>-trade` and `<sha>-research` (and `<sha>`,
  the research image). `local.family_target` in `services.tf` gives each family its target, and a family's
  Terraform-registered revision runs `${var.image_tag}-<target>`. `pmbot-deploy` keeps the target of the latest revision and
  swaps only the SHA, so a later deploy of any SHA stays on the family's image. `var.image_tag` must be a SHA whose five tags
  exist in ECR (`aws ecr describe-images`); `ci/test_services_maps.py` refuses the pre-split bootstrap SHA.
- **Roles reach the tasks in two applies.** The first PR created the roles, the policies and the alarm. The second
  (`local.family_plane` in `services.tf`) sets every family's `task_role_arn` to its plane role and its environment
  `SPORTS_S3_QUEUE=<plane>` in the same revision, and registers new revisions; they reach the services with the next
  `pmbot-deploy` at the running SHA. The queue variable is what stops one plane's drainer from trying (and being denied)
  another plane's files. **Never deploy an image older than the `SPORTS_S3_QUEUE` support (polymarket-bot EP-031-T4) under
  these revisions:** it would drain the shared queue under a plane role and be denied. To go back to such an image, revert
  this change first. Rolling back to a previous revision (`update-service --task-definition <arn>`) is always safe: those
  revisions carry the legacy role and no queue variable.
- **Passing the roles.** `pmbot-github-deploy` registers revisions that name these roles, so its `PassTheTaskRoles`
  statement lists them. That statement is owner-applied (the guard refuses `github_*`), and must exist before the revisions
  are registered. The scheduler role (`pmbot-scheduler`) may pass `pmbot-task-model`, which the two scheduled families use.
- **Alarm.** `pmbot-s3-put-forbidden` fires on the first `s3_put_forbidden` log line of any task: a plane role was denied an
  upload and `s3sync` parked the marker under `.s3-queue/<plane>/forbidden/`.
- **Editing a plane's prefixes.** Change `local.planes` in `iam.tf` and `PLANE_WRITE_PREFIXES` in `ci/plan_guard.py` together;
  `ci/test_plan_guard.py` fails when they differ. Prefixes of two planes are disjoint except the pairs in
  `ALLOWED_OVERLAPS` (`ci/test_plan_guard.py`), which must list every overlap exactly.
- **Guard coverage.** The managed-policy check covers `aws_iam_role_policy_attachment` only. Not checked: a policy or
  attachment whose `role` is unknown at plan time, `managed_policy_arns` or `inline_policy` on `aws_iam_role`,
  `aws_iam_policy_attachment`, and `aws_iam_role_policies_exclusive`; review those by hand in a PR.

## Status page (CH-009)

https://pmbot.protoapp.xyz is a static page (polymarket-bot `web/pmbot-status`) served from the private bucket
`pmbot-site-<account>` through CloudFront (OAC; `status.tf`). The `pmbot-status` service (`python -m
sports.ops.status_page loop`, collect image, `/data` read-only, `SPORTS_S3=off`) writes `status.json` every 60 s;
CloudFront never caches that path. polymarket-bot's `pmbot-site.yml` uploads `index.html`, `scoreboard.json` and
`assets/` as `pmbot-github-deploy` and invalidates the two revalidated paths. Runbook: polymarket-bot
`docs/runbooks/cloud-deploy.md`, "Public status page".

- **IAM.** `pmbot-status` may `PutObject` `status.json` and open ECS Exec channels, nothing else. The deploy role may
  write `index.html`, `scoreboard.json` and `assets/*` (never `status.json`), list the bucket, invalidate the
  distribution and pass `pmbot-status` to ECS. The plan and apply roles read the bucket and CloudFront; the apply role
  may edit the bucket and the `Product=pmbot` distribution. `ci/test_status_site.py` pins all of this.
- **First apply is the owner's.** The change edits the three `github_*` policies, so `plan_guard.py` refuses it in CI
  (by design). Apply it from a saved plan (Manual apply) from the PR branch, then merge: the PR's plan is then clean.
  Expected: 11 to add, 3 to change (the `github_*` policies), 0 to destroy.
- **Then, in order:** the DNS record (`products/pmbot/dns`, below); the repository variables
  `PMBOT_SITE_BUCKET` = output `site_bucket_name` and `PMBOT_SITE_DISTRIBUTION_ID` = output `site_distribution_id`
  on `OptimusFoundry/polymarket-bot`; a `pmbot-deploy` run, which registers `pmbot-status:2` with the current
  `<sha>-collect` image; finally `aws ecs update-service --cluster pmbot --service pmbot-status --desired-count 1`.
- **Parked at 0 on purpose.** The Terraform-registered revision runs `${var.image_tag}-collect`, the bootstrap image,
  which has no status writer. Like every family, the running revision belongs to `pmbot-deploy`
  (`ignore_changes = [desired_count, task_definition]`).
- **DNS record.** `products/pmbot/dns/` is its own root (state key `dns/terraform.tfstate` in `pmbot-terraform-state`):
  one `cloudflare_dns_record` `pmbot.protoapp.xyz CNAME <distribution>.cloudfront.net`, not proxied (CloudFront
  terminates TLS on the platform wildcard certificate). It reads the Cloudflare global key from SSM, so CD never
  plans it; the owner applies it once after the distribution exists:

      terraform -chdir=products/pmbot/dns init -input=false
      TF_VAR_cloudflare_email=<Cloudflare email> terraform -chdir=products/pmbot/dns plan -input=false -out=tfplan-dns
      terraform -chdir=products/pmbot/dns apply tfplan-dns && rm products/pmbot/dns/tfplan-dns

  Expected: 1 to add. Check: `dig +short pmbot.protoapp.xyz CNAME` names the distribution, and
  `curl -sSI https://pmbot.protoapp.xyz` answers `HTTP/2 200` once the page is uploaded.

## Compute: t4g.xlarge, unlimited credits, per-family data dirs (EP-032)

- **Instance.** `var.instance_type` is `t4g.xlarge` (4 vCPU, 16 GiB). The launch template pins `credit_specification { cpu_credits = "unlimited" }`:
  the account default for T4g is already unlimited, so a CPU-bound predictor run (about one full vCPU) is never throttled and surplus
  credits are billed (about $0.05 per vCPU-hour) instead. Pinning stops an account-default change from switching the host to `standard`.
- **ECS memory.** User data adds `ECS_RESERVED_MEMORY=512` to `/etc/ecs/ecs.config`: the ECS agent registers 512 MiB less memory, which
  stays free for the OS and the agent.
- **Per-family data dirs.** User data creates `/data/<family>` (owner 10001:10001) for every family in `local.data_families`: recorder,
  maker-paper, maker-live, ingame-capture, xvenue-poller, rewards-poll, daily-ingest, predictor, research. Nothing mounts them until the
  services PR sets each task definition's `host_path`. Docker creates a missing bind-mount source as `root:root`, which the container user
  (10001) cannot write, so the dirs must exist on the host first.
- **Applying this moves nothing.** The launch template is updated in place (a new version; `name_prefix` and `create_before_destroy`
  unchanged) and the ASG follows `latest_version` in place; there is no `instance_refresh`, so the running instance keeps running.
  Expected plan: `0 to add, 2 to change, 0 to destroy` (`aws_launch_template.instance`, `aws_autoscaling_group.pmbot`); `plan_guard`
  passes (it refuses only a delete or replace of a guarded type). The new type, credit setting and directories reach a host only when the
  instance is replaced: after the flush in polymarket-bot `docs/runbooks/data-plane-compute.md`, terminate it in the ASG
  (`aws autoscaling terminate-instance-in-auto-scaling-group --no-should-decrement-desired-capacity`).
- **Tests.** `ci/test_compute.py` pins the type, the credit specification, `ECS_RESERVED_MEMORY`, the directory list and the absence of
  `instance_refresh`.

## Bootstrap (done once, from a workstation with admin credentials)

The CD roles cannot create themselves. Run this once, from the repo root, on the branch that adds `github-cd.tf`:

    terraform -chdir=products/pmbot init -reconfigure -input=false
    terraform -chdir=products/pmbot plan -input=false -out=tfplan-ch008-bootstrap   # 6 to add: the github_* roles and policies
    terraform -chdir=products/pmbot show -json tfplan-ch008-bootstrap > /tmp/ch008-plan.json
    python3 products/pmbot/ci/plan_guard.py /tmp/ch008-plan.json   # exit 1: exactly the 6 CD-role creates, owner-applied by design
    terraform -chdir=products/pmbot apply tfplan-ch008-bootstrap
    rm products/pmbot/tfplan-ch008-bootstrap /tmp/ch008-plan.json
    rm products/pmbot/terraform.tfvars          # after checking it only held image_tag and sports_s3_mode = the defaults
    terraform -chdir=products/pmbot plan -input=false -detailed-exitcode      # 0: no changes

Then set the repository variables (role ARNs are not secrets):

| Repository | Variable | Value |
|---|---|---|
| `OptimusFoundry/polymarket-bot` | `PMBOT_DEPLOY_ROLE_ARN` | output `github_deploy_role_arn` |
| `OptimusFoundry/base-infra` | `AWS_REGION` | `us-east-1` |
| `OptimusFoundry/base-infra` | `PMBOT_TF_APPLY_ROLE_ARN` | output `github_terraform_role_arn` |
| `OptimusFoundry/base-infra` | `PMBOT_TF_PLAN_ROLE_ARN` | output `github_terraform_plan_role_arn` |

The trust policies use the immutable OIDC subject claims both repositories emit (`gh api
repos/<owner>/<repo>/actions/oidc/customization/sub`). polymarket-bot `main` is `var.github_oidc_subject`; base-infra
is `var.base_infra_oidc_subject_prefix` plus `:ref:refs/heads/main` (apply) or `:pull_request` (plan).

## Manual apply (the guard refused, or a change to the CD roles)

    terraform -chdir=products/pmbot init -reconfigure -input=false
    terraform -chdir=products/pmbot plan -out=tfplan-manual
    terraform -chdir=products/pmbot show tfplan-manual      # read it: "must be replaced" and "destroyed" first
    terraform -chdir=products/pmbot apply tfplan-manual
    rm products/pmbot/tfplan-manual

Plan files hold full variable values and are never committed (`.gitignore` has `tfplan*`). Never run
`terraform apply` without a saved plan file. A CD-role change merged to `main` fails its CI apply at the guard;
the owner runs this from `main` afterwards. The same steps work from the PR branch before merging: the state then
matches the branch, the PR's plan is clean (the check is green) and the merge applies nothing.

## Owner actions still open (carried over from CH-007)

1. Confirm the `platform-alerts` email subscription if it has not been confirmed yet.
2. Nothing goes under `/pmbot/*` in SSM until the owner's explicit live go. No task role can read it since EP-031.
3. Follow the runbook: one manual daily-ingest run, the 24 h checklist, then cutover (`sports_s3_mode = "rw"` by a
   PR changing the default, Mac copies stopped, instance replaced, then a `pmbot-deploy` run with the running SHA).

## History: first deploy (CH-007, done 2026-10-01)

Phase A applied ECR and the push role, CI pushed the first image (`4b1cc7a990362d51d4eb0c7fadbae29cb72b7c8d`),
and Phase B applied the full stack with that tag. That tag is now `var.image_tag`'s default.

## Notes for the owner's decisions

- **D3, `sports_s3_mode`.** Default `rw` since the CH-007 cutover: the Mac recorder and maker copies are stopped. A CD apply must
  never flip it back to `ro`. The flip was done by a PR changing the default in `variables.tf`, then a `pmbot-deploy`
  run with the running SHA (polymarket-bot runbook, Cutover step 4).
- **Replacing the instance.** A plan never replaces it (the ASG has no `instance_refresh`). Terminate the instance in
  the ASG (output `asg_name`) only after `s3sync backfill` and the paper-journal carry-over in the runbook.
- **AMI drift.** The AMI id comes from the SSM recommended-image pointer, so a later plan may show a new launch
  template version. That is expected and does not touch the running instance.
- **Kill switch.** `aws ecs update-service --cluster pmbot --desired-count 0` stops a service; `desired_count` is
  ignored by Terraform, so scale it back with an explicit `--desired-count 1`.
- **Lock file.** `.terraform.lock.hcl` is tracked, as in the other stacks.

## Cost (approximate, us-east-1, on-demand, 2026-09-30)

| Item | Per month |
|---|---|
| t4g.xlarge, 1 instance, unlimited credits (surplus credits only above the 160% baseline, about $0.05 per vCPU-hour) | about $98 |
| 100 GB gp3 root volume | about $8 |
| Public IPv4 address | about $3.70 |
| Container Insights (single instance, 5 services) | about $5 to $10 |
| Alarms (9, or 11 with the predictor enabled) and six custom metrics | about $3 |
| Log ingestion and storage, 30 days | about $0.50 per GB ingested |
| ECR storage, 120 images | about $1 to $4 |
| **Total, before logs and S3 data** | **about $117 to $124** |

S3 storage and requests for the data bucket are separate and already exist. Check the AWS pricing pages before
relying on these figures.
