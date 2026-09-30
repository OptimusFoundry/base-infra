# pmbot

The polymarket-bot sports stack (`OptimusFoundry/polymarket-bot`, formerly `SAVentures/polymarket-bot`) on AWS.
One linux/arm64 image runs the recorder, the paper maker, three research collectors and a daily ingest
as ECS tasks on a dedicated `t4g.large` in a dedicated `pmbot` ECS cluster. The plan is CH-007 in the
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
| ECR repository | `pmbot` (IMMUTABLE, scan on push, keeps the 30 newest images) |
| GitHub push role | `pmbot-github-ecr-push` (push to `pmbot` only, trusted for `main` of `var.github_repo`) |
| Instance role / profile / SG | `pmbot-ecs-instance` (no ingress, all egress, no key pair) |
| Launch template + ASG | `pmbot-ecs-*`, exactly 1 instance, 100 GB encrypted gp3, IMDSv2 hop limit 1 |
| Task / execution / scheduler roles | `pmbot-task`, `pmbot-task-execution`, `pmbot-scheduler` |
| Log groups | `/ecs/pmbot/<name>` for the 6 tasks, 30 days |
| Task definitions | `pmbot-<name>` x 6 (bridge, EC2, arm64) |
| Services | `pmbot-recorder`, `pmbot-maker-paper`, `pmbot-ingame-capture`, `pmbot-xvenue-poller`, `pmbot-rewards-poll` |
| Schedule | `pmbot-daily-ingest`, 06:00 America/New_York, one attempt |
| Alarms | 5 x `pmbot-<name>-not-running`, `pmbot-daily-ingest-failed`, `pmbot-daily-ingest-missing`, to `platform-alerts` |

`platform` is read through `terraform_remote_state` for the VPC, the public subnets and the `platform-alerts`
topic only. The shared `ecs-cluster` is never read or changed, and nothing in `platform/` or another product
changes: a full plan from an empty state is 47 creates, all pmbot-named, and no update, replace or destroy.

## Topology (dedicated cluster, owner decision D1 = b)

- pmbot has its own ECS cluster, so no other product's task can land on the pmbot instance. The instance joins it
  by user data (`ECS_CLUSTER=pmbot`) and still registers the attribute `pmbot=dedicated`; every task definition,
  service and the schedule keep the `memberOf(attribute:pmbot == dedicated)` constraint as belt and braces.
- Services and the scheduled task place through the `pmbot` capacity provider strategy, not `launch_type`.
- The instance sits in a public subnet with a public IPv4 because the platform has an internet gateway and no
  NAT. The security group has no inbound rule; the only way onto the host is Session Manager.
- `/data` is a host directory on the root volume (owned by uid 10001). Every task mounts it. The recorder, the
  collectors and the maker write there, and `sports.core.s3sync` uploads to `s3://polymarket-bot-data-339713122183`.
- Services deploy stop-then-start (`deployment_minimum_healthy_percent = 0`, `maximum = 100`), so the old task
  gets SIGTERM and 120 s before the new one starts. Two recorders, or two makers on one `/data`, never run at once.
- Images are pinned by git SHA (`var.image_tag`, no default, `latest` refused). A deploy is a new tag and an apply
  of a saved plan; a rollback is the previous tag.
- Liveness alarms use `ECS/ContainerInsights` `RunningTaskCount` (`ClusterName = pmbot`), below 1 for 5 x 60 s,
  missing data counted as breaching.

## Two-phase apply

The repository must exist before CI can push an image, and the services need an image that exists.

    # Phase A (owner): ECR and the GitHub push role only
    terraform -chdir=products/pmbot apply tfplan-phase-a

Then GitHub setup (runbook, first deploy): repository variables `AWS_REGION=us-east-1`,
`PMBOT_ECR_REPOSITORY=pmbot`, `PMBOT_ECR_PUSH_ROLE_ARN=<role arn>`, push `main`, and confirm CI pushed `:<sha>`.
The role ARN is the `github_push_role_arn` output; if it comes back empty, use

    aws iam get-role --role-name pmbot-github-ecr-push --query Role.Arn --output text

Phase B: set `image_tag = "<sha>"` in `products/pmbot/terraform.tfvars` (gitignored), plan, read the plan, apply it.

    terraform -chdir=products/pmbot plan -out=tfplan-phase-b
    terraform -chdir=products/pmbot apply tfplan-phase-b

Plan files hold full variable values and are never committed (`.gitignore` has `tfplan*`). Delete each one after
applying it. Never run `terraform apply` without a saved plan file.

## Pending plans

`tfplan-phase-a` and `tfplan-review` are NOT yet saved: `terraform init` with the real backend fails with
`S3 bucket "pmbot-terraform-state" does not exist` (checked 2026-09-30). Once the owner has created the bucket
(Owner action 1) they are produced with:

    terraform -chdir=products/pmbot init -reconfigure
    terraform -chdir=products/pmbot plan -input=false -var image_tag=bootstrap-unused -target=aws_ecr_repository.pmbot -target=aws_ecr_lifecycle_policy.pmbot -target=aws_iam_role.github_push -target=aws_iam_role_policy.github_push -out=tfplan-phase-a
    terraform -chdir=products/pmbot plan -input=false -var image_tag=review-placeholder -out=tfplan-review

Expected: Phase A `Plan: 4 to add, 0 to change, 0 to destroy.` (ECR repository, lifecycle policy, push role, push
policy). The review plan is `Plan: 47 to add, 0 to change, 0 to destroy.` and exists only to be read: its
`image_tag` is a placeholder, so it is not deployable. Before the bucket existed, the same plans were run from a
scratch copy with a local backend and gave exactly these counts; the scope proof (all creates, all pmbot-named)
and the diff against `sports/ops/services.py` passed on that plan.

## Owner actions, in order

1. Create the state bucket and enable versioning:

       aws s3 mb s3://pmbot-terraform-state --region us-east-1
       aws s3api put-bucket-versioning --bucket pmbot-terraform-state --versioning-configuration Status=Enabled

2. Save the two plans (above), read `tfplan-phase-a`, then apply it.
3. GitHub repository variables and the first CI push.
4. Phase B: plan with the pushed SHA, review, apply.
5. Confirm the `platform-alerts` email subscription if it has not been confirmed yet.
6. Nothing goes under `/pmbot/*` in SSM until the owner's explicit live go. The task role can already read it.
7. Follow the runbook: one manual daily-ingest run, the 24 h checklist, then cutover (`sports_s3_mode = "rw"`,
   Mac copies stopped, instance replaced).

## Notes for the owner's decisions

- **D3, `sports_s3_mode`.** Default `ro`: the Mac recorder and maker still write the canonical prefix. Flip to `rw`
  only after the Mac copies are stopped, then replace the instance so `/data` starts empty.
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
| t4g.large, 1 instance | about $49 |
| 100 GB gp3 root volume | about $8 |
| Public IPv4 address | about $3.70 |
| Container Insights (single instance, 5 services) | about $5 to $10 |
| Alarms (7) and two custom metrics | about $1.30 |
| Log ingestion and storage, 30 days | about $0.50 per GB ingested |
| ECR storage, 30 images | about $1 to $3 |
| **Total, before logs and S3 data** | **about $68 to $75** |

S3 storage and requests for the data bucket are separate and already exist. Check the AWS pricing pages before
relying on these figures.
