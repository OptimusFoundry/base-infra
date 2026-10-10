# orca

The **tickuptoks** app (`SAVentures/tickuptoks`) served at `orca.protoapp.xyz`.

The slug and the repo name differ on purpose. `orca` is the infrastructure
identity — subdomain label, SSM prefix (`/orca/*`), ALB `X-Product-Id` header
value, ECS/ECR resource names, and the app's own `PRODUCT_NAME` (which stamps
Stripe metadata). Nothing keys off the repo name.

## What this stack owns

| Resource | Name |
|---|---|
| Webapp bucket + CloudFront | `protoapp-orca-webapp` (module convention) |
| API service | ECS `orca-api`, ECR `orca-server`, target group `orca-api-tg` |
| Render service | ECS `orca-render-service`, ECR `orca-render-service` |
| Migrator | task definition `orca-migrator` (no service), ECR `orca-migrator` |
| Media bucket | `protoapp-orca-media` (public-read) + IAM user of the same name |
| ALB rule priority | **300** (sjocamp 100, meerkat 200) |
| Terraform state | `s3://protoapp-orca-terraform-state` |

`orca-terraform-state` was already taken in S3's global namespace — hence the
`protoapp-` prefix, which matches the module's bucket naming convention anyway.

Two ECS services rather than one because tickuptoks splits rendering out:
base-server publishes render jobs on `content-job.render.requested` and
render-service (Remotion + headless Chromium) consumes them, replying on
`content-job.render.results`. The two sides name that topic pair with
**different** environment variables, so `render-service.tf` pins both from one
`locals` block. Overriding one side alone breaks the hand-off silently — no
error surfaces on either end, jobs just never complete.

## Secrets

Account-wide values live at `/platform/*` and are read through `data.tf`:
resend, openai, gemini, **fal**, **elevenlabs**, stripe secret key, RDS master
credentials. `fal` and `elevenlabs` were added to the platform stack for this
product — no other product uses them yet.

There is deliberately **no** `/platform/ai/anthropic_api_key`. The only
Anthropic consumer is the content-job script provider, which is opt-in
(`CONTENT_JOB_SCRIPT_PROVIDER` defaults to `gemini`) and treats the key as
optional. Add the parameter when a real key exists rather than parking a
placeholder that reads as configured.

Per-product values come from the gitignored `secrets.auto.tfvars`. Rotate by
editing that file and running `terraform apply` — never `aws ssm put-parameter`,
which is invisible to the config and gets clobbered on the next apply.

Media-bucket credentials are the exception to the tfvars pattern: the bucket and
IAM access key are created by this stack rather than imported, so
`aws_iam_access_key.media.secret` is known to Terraform and feeds both task
definitions directly. No tfvars round-trip and no manual re-seed on rotation.

## Bootstrap checklist

Applied on 2026-07-26: edge, routing, secrets and both ECS services are live.
`orca.protoapp.xyz` resolves, serves a valid certificate, and `/api/*` reaches
`orca-api-tg` (it answers 503 rather than the listener's default 404, which is
how you can tell the header-matched rule is firing).

Both ECR repositories are empty, so neither service can place a task yet. The
steps below are what turn that into a working app; none can be done by `apply`.

### 1. Register orca's own webhook endpoints

Current state of `secrets.auto.tfvars`:

| Value | State |
|---|---|
| `google_client_id` / `google_client_secret` | **Done** — OAuth client issued for `orca.protoapp.xyz` |
| `jwt_secret` | **Done** — generated fresh. Never copy a sibling's; it would make their sessions valid here |
| `default_email_sender_address` | **Done** — `no-reply@protoapp.xyz`, already Resend-verified (meerkat sends from it) |
| `stripe_webhook_secret` | **Placeholder** — copied from meerkat |
| `resend_webhook_secret` | **Placeholder** — copied from sjocamp |
| `stripe_billing_portal_config_id` | Empty → Stripe account default |

The two copied values put orca on the same live Stripe/Resend accounts as its
siblings, which is what the platform-shared `stripe_secret_key` and
`resend_api_key` expect — a strict improvement on the Stripe-CLI local-listen
secret that was there before.

**They do not make webhooks work.** A webhook signing secret is bound to the
specific endpoint it was issued for, so orca's server will fail signature
verification on anything delivered to `orca.protoapp.xyz`. Until orca has its
own endpoints, subscription state changes will not reach the database:

| Register | Endpoint |
|---|---|
| Stripe → new live-mode webhook endpoint | `https://orca.protoapp.xyz/api/webhooks/stripe` |
| Resend → new webhook endpoint | `https://orca.protoapp.xyz/api/webhooks/resend` |

Put each new signing secret in `secrets.auto.tfvars`, then `terraform apply`.

Leave `stripe_billing_portal_config_id` empty unless you want a
product-specific portal — a `bpc_*` borrowed from sjocamp would show sjocamp's
products, and a test-mode config will not resolve in live mode at all.

### 2. Create the database

The API connects as the RDS **master** user (same as sjocamp and meerkat) and
only needs its own database. `/orca/db_name` is `orca`.

```bash
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=ECS AutoScaling Group" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

RDS_HOST=$(aws ssm get-parameter --name /platform/rds/host --query Parameter.Value --output text)

# Blocks — run in its own terminal.
aws ssm start-session --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$RDS_HOST\"],\"portNumber\":[\"5432\"],\"localPortNumber\":[\"15432\"]}"
```

Then, in another terminal:

```bash
RDS_MASTER_USER=$(aws ssm get-parameter --name /platform/rds/master_username --with-decryption --query Parameter.Value --output text)
RDS_MASTER_PASS=$(aws ssm get-parameter --name /platform/rds/master_password --with-decryption --query Parameter.Value --output text)

PGPASSWORD="$RDS_MASTER_PASS" psql -h localhost -p 15432 -U "$RDS_MASTER_USER" -d postgres \
  -c 'CREATE DATABASE orca;'
```

Schema migrations are not run by hand: `orca-server.yml` runs the
`orca-migrator` task (ECR `orca-migrator`) on every deploy, before the API rolls.

### 3. Push images

Both ECS services reference `:latest` in ECR and will fail to place tasks until
an image exists. Merging to `main` in the app repo runs the three workflows;
`workflow_dispatch` triggers them without a code change.

`orca-render-service` is the slow one — the Remotion image installs Chromium
shared libraries and pre-downloads the render browser under QEMU emulation for
arm64. Budget 15–25 minutes on a cold cache.

### 4. Seed the Stripe billing catalog

Required once before anyone can sign in — sign-up resolves a plan from the
catalog. From `tickuptoks/base-server`, with prod `DB_*` and `STRIPE_SECRET_KEY`
exported:

```bash
CONFIRM=prod go run ./cmd/catalog-sync --env=prod
```

Objects are stamped with `metadata.product = orca`, which is what keeps them
distinct from meerkat's and sjocamp's on the shared Stripe account.

### 5. Smoke test

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://orca.protoapp.xyz/api/health
aws logs tail /orca/api --follow
aws logs tail /orca/render-service --follow
```

Then: SPA loads, email sign-up delivers, Google OAuth completes, a content job
reaches the render service and produces a video URL under
`https://protoapp-orca-media.s3.us-east-1.amazonaws.com/`.

## Known gaps

- **No Sentry.** The webapp calls `initSentry()`, which no-ops without
  `VITE_SENTRY_DSN`. sjocamp wires `/sjocamp/sentry/*`; orca has no equivalent
  parameters and the build passes no DSN. Add both together if you want it.
- **Render capacity is one task on a shared host.** The ECS cluster is a single
  `t4g.large`. `orca-render-service` reserves 1536 MB soft with no hard cap, on
  purpose: Chromium's RSS spikes while compositing, and a hard cap it briefly
  crosses kills the task mid-render rather than slowing it. Concurrent renders
  will contend — scale the ASG before raising `render_service_desired_count`.
