// Per-product SSM, under /orca/*.
//
// Secret values are supplied by Terraform variables sourced from a gitignored
// `secrets.auto.tfvars`. Rotate by editing that file and running
// `terraform apply` — never via `aws ssm put-parameter`.
//
// Account-wide secrets (resend, openai, gemini, fal, elevenlabs, stripe keys,
// db master creds) live at /platform/* — see platform/shared-secrets.tf.
//
// Names below carry a domain segment (auth/, payments/, email/, storage/, db/,
// app/), matching env-registry's env-var-rename: SAVentures/env-registry
// docs/superpowers/specs/2026-07-26-env-var-rename-design.md. Every `moved`
// block below pairs with a genuine SSM parameter replacement — the path
// (hence the resource's `name`) is ForceNew, so `moved` prevents state churn
// on the Terraform address but does not avoid the destroy+create API calls.
// Values are safe: env-registry/values/*.enc.env holds them independently of
// what is live in SSM.

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

// SSM rejects an empty parameter value, and the app treats an unset billing
// portal config as "use the Stripe account default" — so an empty variable
// means no parameter rather than a parameter holding "".
resource "aws_ssm_parameter" "payments_stripe_billing_portal_config_id" {
  count = var.payments_stripe_billing_portal_config_id == "" ? 0 : 1

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

// --- Sentry (stubbed; see secret-variables.tf) ---
//
// Already domain-qualified before this rename — see env-registry's spec,
// "sentry and capture_worker groups already exist and are unchanged." No
// `moved` block needed: nothing about their address or path changes.
//
// count on emptiness matches stripe_billing_portal_config_id above: SSM rejects
// an empty value, and an absent parameter is the honest representation of
// "not configured" — a parameter holding "" reads as configured when it isn't.

resource "aws_ssm_parameter" "sentry_webapp_dsn" {
  count = var.sentry_webapp_dsn == "" ? 0 : 1

  name  = "/${var.product}/sentry/webapp_dsn"
  type  = "String"
  value = var.sentry_webapp_dsn
}

resource "aws_ssm_parameter" "sentry_auth_token" {
  count = var.sentry_auth_token == "" ? 0 : 1

  name  = "/${var.product}/sentry/auth_token"
  type  = "SecureString"
  value = var.sentry_auth_token
}

resource "aws_ssm_parameter" "sentry_org" {
  count = var.sentry_org == "" ? 0 : 1

  name  = "/${var.product}/sentry/org"
  type  = "String"
  value = var.sentry_org
}

resource "aws_ssm_parameter" "sentry_webapp_project" {
  count = var.sentry_webapp_project == "" ? 0 : 1

  name  = "/${var.product}/sentry/webapp_project"
  type  = "String"
  value = var.sentry_webapp_project
}
