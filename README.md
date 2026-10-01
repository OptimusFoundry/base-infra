# infra-setup

AWS infrastructure split into a shared platform stack and one Terraform stack per product. The split lets multiple products share one AWS account — one RDS, one ECS cluster, one ALB — without duplicating cost per product.

## Layout

```
infra-setup/
├── platform/               # shared: VPC, RDS, ECS cluster, ALB, Kafka, IAM
└── products/
    ├── _template/          # starting point for a new product
    ├── meerkat/            # meerkat-only: S3, CloudFront, ACM, ECS service, SSM, DNS
    ├── sjocamp/
    ├── orca/               # the tickuptoks app
    ├── aitravel/           # the AITravel iOS app's API
    └── pmbot/
```

### State

- **platform** state: `s3://protoapp-infra-terraform-state/state/terraform.tfstate` (unchanged from the pre-split setup)
- **products/meerkat** state: `s3://protoapp-terraform-state/state/terraform.tfstate` (bucket name predates the meerkat rename and is deliberately unchanged)
- **products/sjocamp** state: `s3://sjocamp-terraform-state/state/terraform.tfstate`
- **products/orca** state: `s3://protoapp-orca-terraform-state/state/terraform.tfstate` (`orca-terraform-state` was taken globally)
- **products/aitravel** state: `s3://aitravel-terraform-state/state/terraform.tfstate`

Future products get their own state bucket and live in `products/<name>/`.

## How products share the platform

`platform/` exports outputs (ALB ARN, ECS cluster, VPC, subnets, task role, kafka DNS) that product stacks read via `terraform_remote_state`. Each product stack then provisions only its own resources on top.

Routing (once multiple products exist): each product's CloudFront forwards `/api/*` to the shared ALB with a custom `X-Product-Id` header. A per-product listener rule on the ALB matches that header and forwards to the product's target group. One ALB, N products, no path or host collisions.

## Getting started

See [RUNBOOK.md](./RUNBOOK.md) for the original state migration — how existing resources moved from the pre-split state into platform + the product stack without recreating anything.

## Tiers: prototype vs product

Every deployment is one of two tiers, set by `tier` on `modules/product`:

| | prototype | product |
|---|---|---|
| Domain | `<slug>.protoapp.xyz` | its own domain |
| Certificate | shared `*.protoapp.xyz` wildcard | its own, created in its stack |
| Log retention | 7 days | 90 days |
| Alarms | none | no healthy hosts + target 5xx |

A prototype is disposable and may break quietly. A product is shipped software
and pages you. Placement is enforced: `modules/product` validates `domain`
against `tier`, so a prototype cannot be pointed at a real domain and a product
cannot squat the umbrella zone. A violation fails at plan time, before anything
reaches AWS.

Certificate is the same kind of convention, not an enforced rule: `acm_certificate_arn`
is a completely unconstrained input. A `tier = "product"` stack that passes the
platform wildcard cert plans and applies with no complaint from Terraform.

To promote a prototype, see the spec:
`docs/superpowers/specs/2026-07-25-product-tiers-design.md`.

## Adding a new project

0. Decide the tier first. These steps produce a **prototype**: the template
   hardcodes `tier = "prototype"`, uses the umbrella Cloudflare zone and the
   shared wildcard cert, and passes no `alerts_topic_arn`. Starting straight
   from a **product** is a different path — register the domain and change
   four lines in the module call. See "Promotion: prototype → product" in
   the spec (`docs/superpowers/specs/2026-07-25-product-tiers-design.md`)
   for the exact steps.
1. `cp -r products/_template products/<slug>` and replace every `PROJECT_SLUG`
2. Pick an unused `alb_rule_priority` — sjocamp 100, meerkat 200, orca 300,
   aitravel 310; new projects from 320 in steps of 10. AWS rejects duplicate
   priorities.
3. `aws s3 mb s3://<slug>-terraform-state`
4. Add the project's ECS task definition and service in `products/<slug>/`,
   wiring `load_balancer.target_group_arn` to `module.product.target_group_arn`
5. `terraform init && terraform apply`
6. Create the project's database and user on the shared RDS instance
7. Populate `/<slug>/*` SSM via a gitignored `secrets.auto.tfvars`

### What the module does and does not cover

`modules/product/` owns **edge and routing**: S3, CloudFront, Cloudflare DNS, the
ALB target group and its `X-Product-Id` listener rule, plus two target-group
CloudWatch alarms (products only — see Tiers above).

It deliberately excludes **compute** (ECS task definition and service) and the
**SSM manifest**. Both are irreducibly product-specific — env blocks and manifest
fields differ per product — so sharing them would mean threading a large map of
pass-through variables through the module, which is worse than the duplication it
removes.

### Session cookies must be host-only

`protoapp.xyz` is not on the Public Suffix List, so a cookie scoped to
`.protoapp.xyz` is readable *and writable* by every sibling subdomain. Set session
cookies with no `Domain=` attribute and `SameSite=Lax` minimum. Cross-project SSO
is a non-goal; the design spec records the sanctioned path if that ever changes.

### Limits

The ALB allows 100 rules per listener, one per project — roughly 95 projects.

## Shared vs per-product

| Resource | Location |
|---|---|
| VPC, subnets, NACLs | platform |
| RDS Postgres instance | platform (one logical DB per product) |
| ECS cluster | platform (one service per product) |
| ALB | platform (one listener rule + target group per product) |
| Kafka broker | platform (one topic prefix per product) |
| CloudFront + S3 webapp | product (via `modules/product`) |
| ACM wildcard cert (`*.protoapp.xyz`) | platform |
| Cloudflare zone settings | platform |
| Cloudflare DNS record | product (via `modules/product`) |
| CloudFront cache/origin-request policies, SPA function | platform (shared) |
| SNS alerts topic + email subscription | platform (shared) |
| Target-group CloudWatch alarms | product (via `modules/product`, products only) |
| SSM params | `/platform/*` for shared infra, per-product paths for each product |
