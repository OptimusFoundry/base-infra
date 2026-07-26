// Per-product SSM for sjocamp.
//
// Secret values are supplied by Terraform variables sourced from a gitignored
// `secrets.auto.tfvars`. Rotate by editing that file and running
// `terraform apply` — never via `aws ssm put-parameter`.
//
// Account-wide secrets (resend, openai, gemini, stripe keys, turnstile, db
// master creds) live at /platform/* and are read via data.tf.
//
// Names below carry a domain segment (auth/, payments/, email/, db/, app/),
// matching env-registry's env-var-rename: SAVentures/env-registry
// docs/superpowers/specs/2026-07-26-env-var-rename-design.md. See orca's
// secrets.tf for the fuller explanation of why `moved` doesn't avoid the
// underlying SSM replace here (ForceNew name).

moved {
  from = aws_ssm_parameter.web_app_uri
  to   = aws_ssm_parameter.app_webapp_uri
}

moved {
  from = aws_ssm_parameter.google_redirect_uri
  to   = aws_ssm_parameter.auth_google_redirect_uri
}

moved {
  from = aws_ssm_parameter.jwt_secret
  to   = aws_ssm_parameter.auth_jwt_secret
}

moved {
  from = aws_ssm_parameter.google_client_id
  to   = aws_ssm_parameter.auth_google_oauth_client_id
}

moved {
  from = aws_ssm_parameter.google_client_secret
  to   = aws_ssm_parameter.auth_google_oauth_client_secret
}

moved {
  from = aws_ssm_parameter.stripe_webhook_secret
  to   = aws_ssm_parameter.payments_stripe_webhook_secret
}

moved {
  from = aws_ssm_parameter.stripe_billing_portal_config_id
  to   = aws_ssm_parameter.payments_stripe_billing_portal_config_id
}

moved {
  from = aws_ssm_parameter.resend_webhook_secret
  to   = aws_ssm_parameter.email_resend_webhook_secret
}

moved {
  from = aws_ssm_parameter.default_email_sender_address
  to   = aws_ssm_parameter.email_sender_address
}

// --- Derived from product / domain (always TF-managed) ---

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

resource "aws_ssm_parameter" "db_name" {
  name  = "/${var.product}/db/name"
  type  = "String"
  value = var.product
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

resource "aws_ssm_parameter" "payments_stripe_billing_portal_config_id" {
  name  = "/${var.product}/payments/stripe_billing_portal_config_id"
  type  = "String"
  value = var.payments_stripe_billing_portal_config_id
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

// --- Sentry (webapp runtime error reporting) ---
//
// Already domain-qualified before this rename — see env-registry's spec,
// "sentry and capture_worker groups already exist and are unchanged." No
// `moved` block needed.
//
// DSN is technically public (embedded in the client bundle at build time) but
// stored in SSM so the same TF source of truth governs it. Auth token is the
// CI credential that uploads sourcemaps during build — secret.

resource "aws_ssm_parameter" "sentry_webapp_dsn" {
  name  = "/${var.product}/sentry/webapp_dsn"
  type  = "String"
  value = var.sentry_webapp_dsn
}

resource "aws_ssm_parameter" "sentry_auth_token" {
  name  = "/${var.product}/sentry/auth_token"
  type  = "SecureString"
  value = var.sentry_auth_token
}
