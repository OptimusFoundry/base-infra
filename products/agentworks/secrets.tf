// Per-product SSM, under /agentworks/*.
//
// Secret values are supplied by Terraform variables sourced from a gitignored
// `secrets.auto.tfvars`, rendered from env-registry by
// `make secrets PRODUCT=agentworks`. Rotate by editing the value in
// env-registry, re-rendering, and running `terraform apply` — never via
// `aws ssm put-parameter`.
//
// Account-wide secrets (resend, stripe secret key) live at /platform/* — see
// platform/shared-secrets.tf.
//
// Names carry a domain segment (auth/, payments/, email/, storage/, db/, app/,
// gateway/), matching env-registry's catalog. This stack is new, so there are no
// `moved` blocks.

// --- Derived from product / domain (always TF-managed) ---

resource "aws_ssm_parameter" "db_name" {
  name  = "/${var.product}/db/name"
  type  = "String"
  value = var.product
}

resource "aws_ssm_parameter" "app_webapp_uri" {
  name  = "/${var.product}/app/webapp_uri"
  type  = "String"
  value = "https://${var.domain_name}"
}

resource "aws_ssm_parameter" "auth_google_redirect_uri" {
  name  = "/${var.product}/auth/google_redirect_uri"
  type  = "String"
  value = "https://${var.domain_name}/api/auth/google/callback"
}

resource "aws_ssm_parameter" "storage_type" {
  name  = "/${var.product}/storage/type"
  type  = "String"
  value = "s3"
}

// --- Database role (as aitravel) ---
//
// agentworks connects as its own least-privilege role rather than the RDS
// master user. Terraform generates the password; the role and database
// themselves are created by hand on RDS (README.md "Database") because no
// Postgres provider is wired into this repo.
//
// ROTATION ORDER MATTERS. Run `ALTER ROLE agentworks_app PASSWORD '<new>'` on
// RDS FIRST, then replace this value so the parameter and task definition
// follow. Applying first leaves the running task with a password Postgres
// rejects. products/aitravel/README.md "Rotating the DB password" has detail.

resource "random_password" "db_app" {
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "db_username" {
  name  = "/${var.product}/db/username"
  type  = "String"
  value = "${var.product}_app"
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/${var.product}/db/password"
  type  = "SecureString"
  value = random_password.db_app.result
}

// --- Secret values sourced from var.* (secrets.auto.tfvars) ---

resource "aws_ssm_parameter" "auth_jwt_secret" {
  name  = "/${var.product}/auth/jwt_secret"
  type  = "SecureString"
  value = var.auth_jwt_secret
}

resource "aws_ssm_parameter" "auth_google_oauth_client_id" {
  name  = "/${var.product}/auth/google_oauth_client_id"
  type  = "String"
  value = var.auth_google_oauth_client_id
}

resource "aws_ssm_parameter" "auth_google_oauth_client_secret" {
  name  = "/${var.product}/auth/google_oauth_client_secret"
  type  = "SecureString"
  value = var.auth_google_oauth_client_secret
}

resource "aws_ssm_parameter" "payments_stripe_webhook_secret" {
  name  = "/${var.product}/payments/stripe_webhook_secret"
  type  = "SecureString"
  value = var.payments_stripe_webhook_secret
}

resource "aws_ssm_parameter" "email_resend_webhook_secret" {
  name  = "/${var.product}/email/resend_webhook_secret"
  type  = "SecureString"
  value = var.email_resend_webhook_secret
}

resource "aws_ssm_parameter" "email_sender_address" {
  name  = "/${var.product}/email/sender_address"
  type  = "String"
  value = var.email_sender_address
}

resource "aws_ssm_parameter" "gateway_token_key" {
  name  = "/${var.product}/gateway/token_key"
  type  = "SecureString"
  value = var.gateway_token_key
}
