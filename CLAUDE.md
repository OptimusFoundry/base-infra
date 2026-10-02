# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Terraform for a single AWS account hosting several independent products. There is no application code here — only infrastructure. Everything is applied against **live production**; there is no staging copy of any stack.

**Invoke the `terraform-infra` skill before touching any `.tf` file or reading plan output.** It carries the rules that keep a refactor from becoming a destroy-and-recreate. Three agents in `.claude/agents/` handle bigger passes: `terraform-reviewer` (audit a plan pre-apply), `terraform-migrator` (execute a refactor, never applies), `terraform-cost-auditor`.

## Commands

Each directory under `platform/` and `products/*/` is its own root module with its own S3 backend. Always target one explicitly:

```bash
terraform -chdir=platform init
terraform -chdir=products/meerkat plan -out=tfplan   # save the plan
terraform -chdir=products/meerkat apply tfplan       # apply exactly what you read
terraform -chdir=products/meerkat plan -detailed-exitcode   # 0=clean 1=error 2=changes
terraform fmt -recursive
terraform -chdir=<stack> validate
```

Never `terraform apply` without a saved plan file — it re-plans at apply time, so what was reviewed is not provably what runs. `tfplan` contains decrypted variable values; delete it after.

Establish a clean baseline (`-detailed-exitcode` → 0) before editing, or your diff is indistinguishable from pre-existing drift.

There is no test suite and no CI for Terraform in this repo, deliberately: every stack is applied by hand from a saved plan, and the plan review is the gate. Do not add Python/regex tests that pin literal `.tf` values, or a per-product apply workflow — pmbot shipped both and they were removed on 2026-10-01. The `.github/workflows/webapp.yml` referenced in the docs lives in the application repo, not here.

## Stack topology

| Stack | State bucket | Owns |
|---|---|---|
| `platform/` | `protoapp-infra-terraform-state` | VPC, subnets, RDS Postgres, ECS cluster (one t4g.2xlarge host every product runs on, pmbot included), ALB + HTTP listener, Kafka, IAM, wildcard ACM cert, Cloudflare zone settings, shared CloudFront policies + SPA function, SNS alerts topic + email subscription |
| `products/meerkat/` | `protoapp-terraform-state` | product resources (bucket name predates the rename) |
| `products/sjocamp/` | `sjocamp-terraform-state` | product resources |
| `products/orca/` | `protoapp-orca-terraform-state` | the tickuptoks app; two ECS services (API + Remotion render worker) and its own media bucket. See `products/orca/README.md`. |
| `products/aitravel/` | `aitravel-terraform-state` | the AITravel iOS app's Go API (ALB priority 310). See `products/aitravel/README.md`. |
| `products/pmbot/` | `pmbot-terraform-state` | the polymarket-bot paper-trading stack: 5 services + 2 EventBridge-scheduled tasks on the shared cluster, per-plane task roles, a static status site at `pmbot.protoapp.xyz`. No ALB route, so no `modules/product`. See `products/pmbot/README.md`. |
| `modules/product/` | — | shared child module: S3, CloudFront, Cloudflare DNS record, ALB target group + listener rule, target-group CloudWatch alarms (products only) |
| `products/_template/` | — | starting point for a new product; replace every `PROJECT_SLUG` |

Product stacks read `platform/outputs.tf` through `data "terraform_remote_state"`. That read is **one-directional and invisible to the platform stack** — Terraform's dependency graph does not cross state files, so deleting a shared resource looks like an ordinary destroy in `platform/` with no hint that products consume it.

## Routing model

Every product is served the same way regardless of tier: a static SPA on S3 + CloudFront, with `/api/*` forwarded to the one shared ALB. Only the hostname differs — prototypes serve from a `<slug>.protoapp.xyz` subdomain, products serve from their own domain (sjocamp already does, at `app.sjocamp.co`).

CloudFront injects an `X-Product-Id: <slug>` header on the API origin. The ALB listener rule matches `path /api/*` **AND** that header — deliberately not `host_header`, so a product moving to its own apex needs no rule edit. The listener default action is a fixed 404, so an unmatched request never falls through to another product's API.

`alb_rule_priority` must be unique account-wide; AWS rejects duplicates. Current allocation, verified against the live listener: **sjocamp 100, meerkat 200, orca 300, aitravel 310**, new projects from 320 in steps of 10.

A product's slug need not match its repo name — `orca` is the tickuptoks app. The slug is the infrastructure identity (subdomain, SSM prefix, `X-Product-Id`, resource names) and is also what the app sends as `PRODUCT_NAME` to tag its Stripe objects on the shared account.

The binding ceiling on products behind this ALB is **100 target groups per ALB, not adjustable** — not the rules quota.

## Module boundary — what `modules/product` deliberately excludes

The module owns edge and routing, plus the two target-group CloudWatch alarms (products only). ECS task definitions/services and the SSM manifest stay in each product directory, because their *content* is irreducibly per-product. Pulling them in would mean threading a large map of pass-through variables, and an under-specified shared manifest **silently drops fields** — a failure that never shows up as a replacement in a plan.

Wire compute to the module via `load_balancer.target_group_arn = module.product.target_group_arn`.

The module exposes name-override inputs (`s3_bucket_name`, `target_group_name`, `oac_name`, `log_group_name`). **Every one forces replacement if changed.** Existing products pass their live legacy names so migration plans as a no-op; new products omit them and get the convention. Dropping one destroys and recreates the resource it names. Measured, when meerkat's `s3_bucket_name` override was removed on 2026-07-25: the bucket, its policy and its public-access block were replaced, while the CloudFront distribution updated **in place** — so the feared ~20-minute distribution rebuild did not occur for a bucket rename. Note the module sets no `force_destroy`, so the old bucket must be emptied first or the destroy fails with `BucketNotEmpty`.

## Tiers

`modules/product` takes `tier` = `prototype` | `product`. Prototypes live at
`<slug>.protoapp.xyz` on the shared wildcard cert with 7-day logs and no alarms;
products live on their own domain with their own cert, 90-day logs and two
target-group alarms.

Placement **is enforced**. `modules/product/variables.tf` carries a `validation`
block on `domain` that checks it against `tier`: a prototype must serve exactly
`<slug>.protoapp.xyz`, and a product may not serve the umbrella zone or any
subdomain of it. A violation fails at **plan** time, before anything reaches
AWS. The check is a validation rather than a derived hostname on purpose —
`domain` stays a pure input, so promotion remains a three-line change.

Certificate is the same kind of convention, not an enforced rule: `acm_certificate_arn`
is completely unconstrained, so a `tier = "product"` stack passing the platform
wildcard cert plans and applies with no complaint.

Promotion needs a manually-created Cloudflare zone; Terraform owns everything
downstream of that. The SNS email subscription requires a confirmation click
that `apply` cannot perform.

## Secrets

Secrets flow through variables sourced from a gitignored `secrets.auto.tfvars` (all `*.tfvars` are gitignored). **Never `aws ssm put-parameter` on a Terraform-managed parameter** — a hand-set value is invisible to the config and gets clobbered on the next apply.

- `/platform/*` — account-wide (RDS master creds, shared API keys). AI keys live under `/platform/ai/*`: openai, gemini, and — added for orca — fal and elevenlabs.
- `/<product>/*` — per-product
- `/<product>/manifest` — a JSON descriptor of bucket names, distribution ids, ECR/ECS names. Deploy scripts read this instead of hardcoding ids (see WEBAPP_DEPLOYMENT.md).

Before any change that re-paths parameters (a slug rename), verify every value exists in tfvars first. A secret Terraform cannot see gets regenerated — regenerating `jwt_secret` invalidates every active session.

## Refactoring rules

Use declarative blocks, not CLI state commands, because they appear in a plan and can be reviewed before anything is touched:

| Goal | Use | Not |
|---|---|---|
| Rename / move into a module | `moved` | `terraform state mv` |
| Adopt an existing resource | `import` | `terraform import` |
| Stop managing without deleting | `removed` + `lifecycle { destroy = false }` | `terraform state rm` |

Two limits that bite here:

- **`moved` cannot cross resource types.** `aws_alb_target_group` → `aws_lb_target_group` is rejected even though it is the same AWS resource. `products/meerkat/main.tf` carries a `removed` + `import` pair for exactly this, with a comment explaining why — do not "fix" it back into a `moved` block.
- **`moved` cannot cross state files.** Moving a resource between stacks is: import in the destination and apply → back up source state → remove from source config *and* state before any apply there → verify both.

`create_before_destroy` fails on resources with a hardcoded unique `name` (the replacement collides with the original); it needs `name_prefix`.

## Domain constraints

`protoapp.xyz` is not on the Public Suffix List, so a cookie scoped to `.protoapp.xyz` is readable *and writable* by every sibling subdomain. Session cookies must be host-only — no `Domain=` attribute, `SameSite=Lax` minimum. Cross-project SSO is a non-goal.

## In-flight work

**Done (plan task 8):** the product formerly called `protoapp` is now **meerkat** — `products/meerkat/`, SSM under `/meerkat/*`, and `X-Product-Id: meerkat` on the ALB rule. Its state bucket is still `protoapp-terraform-state` and its ECR repo is still `protoapp-capture-worker`; both names are ForceNew and renaming them would destroy state and images for nothing.

**Still pending (plan task 9):** meerkat continues to serve the umbrella apex `protoapp.xyz` (plus `www`). It needs to move to `meerkat.protoapp.xyz` so the apex belongs to no product. That move breaks nine external registrations — Google, X, LinkedIn, Meta, Threads, TikTok, Pinterest and GitHub OAuth callbacks, plus the Stripe webhook — so it is staged additively: both hostnames serve at once while those are re-registered, then the primary flips.

Until task 9 lands, the tier placement validation (`modules/product`, plan Task 6 of the tiers plan) stays off, because meerkat's domain *is* the umbrella zone and would fail it.

sjocamp is **not** moving — it is a product under the tier policy and belongs on its own domain, which is where `app.sjocamp.co` already is. The subdomain plan's Task 10 was retired for exactly that reason.

## Owner preferences

These are personal prototypes. A few minutes of downtime is cheaper than an elaborate zero-downtime dance — state the downtime plainly and let the owner choose rather than defaulting to the complex path.
