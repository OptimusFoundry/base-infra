// Per-product SSM, under /meerkat/*.
//
// Secret values are supplied by Terraform variables sourced from a gitignored
// `secrets.auto.tfvars`. Rotate by editing that file and running
// `terraform apply` — never via `aws ssm put-parameter`.
//
// Account-wide secrets (resend, openai, gemini, stripe keys, turnstile, db
// master creds) live at /platform/* — see platform/shared-secrets.tf.
//
// Names below carry a domain segment (auth/, payments/, email/, social/,
// db/, app/), matching env-registry's env-var-rename: SAVentures/
// env-registry docs/superpowers/specs/2026-07-26-env-var-rename-design.md.
// See orca's secrets.tf for the fuller explanation of why `moved` doesn't
// avoid the underlying SSM replace here (ForceNew name).

moved {
  from = aws_ssm_parameter.web_app_uri
  to   = aws_ssm_parameter.app_webapp_uri
}

moved {
  from = aws_ssm_parameter.google_redirect_uri
  to   = aws_ssm_parameter.auth_google_redirect_uri
}

moved {
  from = aws_ssm_parameter.oauth_redirect_base
  to   = aws_ssm_parameter.auth_oauth_redirect_base
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
  from = aws_ssm_parameter.default_email_sender_address
  to   = aws_ssm_parameter.email_sender_address
}

moved {
  from = aws_ssm_parameter.x_api_key
  to   = aws_ssm_parameter.social_x_api_key
}

moved {
  from = aws_ssm_parameter.x_api_secret
  to   = aws_ssm_parameter.social_x_api_secret
}

moved {
  from = aws_ssm_parameter.linkedin_client_id
  to   = aws_ssm_parameter.social_linkedin_client_id
}

moved {
  from = aws_ssm_parameter.linkedin_client_secret
  to   = aws_ssm_parameter.social_linkedin_client_secret
}

moved {
  from = aws_ssm_parameter.meta_app_id
  to   = aws_ssm_parameter.social_meta_app_id
}

moved {
  from = aws_ssm_parameter.meta_app_secret
  to   = aws_ssm_parameter.social_meta_app_secret
}

moved {
  from = aws_ssm_parameter.threads_app_id
  to   = aws_ssm_parameter.social_threads_app_id
}

moved {
  from = aws_ssm_parameter.threads_app_secret
  to   = aws_ssm_parameter.social_threads_app_secret
}

moved {
  from = aws_ssm_parameter.threads_access_token
  to   = aws_ssm_parameter.social_threads_access_token
}

moved {
  from = aws_ssm_parameter.tiktok_client_key
  to   = aws_ssm_parameter.social_tiktok_client_key
}

moved {
  from = aws_ssm_parameter.tiktok_client_secret
  to   = aws_ssm_parameter.social_tiktok_client_secret
}

moved {
  from = aws_ssm_parameter.pinterest_app_id
  to   = aws_ssm_parameter.social_pinterest_app_id
}

moved {
  from = aws_ssm_parameter.pinterest_app_secret
  to   = aws_ssm_parameter.social_pinterest_app_secret
}

moved {
  from = aws_ssm_parameter.github_webhook_secret
  to   = aws_ssm_parameter.social_github_webhook_secret
}

moved {
  from = aws_ssm_parameter.github_oauth_client_id
  to   = aws_ssm_parameter.auth_github_oauth_client_id
}

moved {
  from = aws_ssm_parameter.github_oauth_client_secret
  to   = aws_ssm_parameter.auth_github_oauth_client_secret
}

// --- Derived from product / domain (always TF-managed) ---

resource "aws_ssm_parameter" "db_name" {
  name  = "/${var.product}/db/name"
  type  = "String"
  value = "base_db" // growth-tools app expects this specific DB name
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

resource "aws_ssm_parameter" "auth_oauth_redirect_base" {
  name  = "/${var.product}/auth/oauth_redirect_base"
  type  = "String"
  value = "https://${var.domain_name}"
}

resource "aws_ssm_parameter" "storage_type" {
  name  = "/${var.product}/storage/type"
  type  = "String"
  value = "s3" // flip to "local" per-product if you don't want S3 media
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

resource "aws_ssm_parameter" "email_sender_address" {
  name  = "/${var.product}/email/sender_address"
  type  = "String"
  value = var.email_sender_address
}

// --- Social platform + integration credentials ---

resource "aws_ssm_parameter" "social_x_api_key" {
  name  = "/${var.product}/social/x_api_key"
  type  = "SecureString"
  value = var.social_x_api_key
}

resource "aws_ssm_parameter" "social_x_api_secret" {
  name  = "/${var.product}/social/x_api_secret"
  type  = "SecureString"
  value = var.social_x_api_secret
}

resource "aws_ssm_parameter" "social_linkedin_client_id" {
  name  = "/${var.product}/social/linkedin_client_id"
  type  = "String"
  value = var.social_linkedin_client_id
}

resource "aws_ssm_parameter" "social_linkedin_client_secret" {
  name  = "/${var.product}/social/linkedin_client_secret"
  type  = "SecureString"
  value = var.social_linkedin_client_secret
}

resource "aws_ssm_parameter" "social_meta_app_id" {
  name  = "/${var.product}/social/meta_app_id"
  type  = "String"
  value = var.social_meta_app_id
}

resource "aws_ssm_parameter" "social_meta_app_secret" {
  name  = "/${var.product}/social/meta_app_secret"
  type  = "SecureString"
  value = var.social_meta_app_secret
}

resource "aws_ssm_parameter" "social_threads_app_id" {
  name  = "/${var.product}/social/threads_app_id"
  type  = "String"
  value = var.social_threads_app_id
}

resource "aws_ssm_parameter" "social_threads_app_secret" {
  name  = "/${var.product}/social/threads_app_secret"
  type  = "SecureString"
  value = var.social_threads_app_secret
}

resource "aws_ssm_parameter" "social_threads_access_token" {
  name  = "/${var.product}/social/threads_access_token"
  type  = "SecureString"
  value = var.social_threads_access_token
}

resource "aws_ssm_parameter" "social_tiktok_client_key" {
  name  = "/${var.product}/social/tiktok_client_key"
  type  = "String"
  value = var.social_tiktok_client_key
}

resource "aws_ssm_parameter" "social_tiktok_client_secret" {
  name  = "/${var.product}/social/tiktok_client_secret"
  type  = "SecureString"
  value = var.social_tiktok_client_secret
}

resource "aws_ssm_parameter" "social_pinterest_app_id" {
  name  = "/${var.product}/social/pinterest_app_id"
  type  = "String"
  value = var.social_pinterest_app_id
}

resource "aws_ssm_parameter" "social_pinterest_app_secret" {
  name  = "/${var.product}/social/pinterest_app_secret"
  type  = "SecureString"
  value = var.social_pinterest_app_secret
}

resource "aws_ssm_parameter" "social_github_webhook_secret" {
  name  = "/${var.product}/social/github_webhook_secret"
  type  = "SecureString"
  value = var.social_github_webhook_secret
}

// --- Capture worker ---
//
// Already domain-qualified before this rename — see env-registry's spec,
// "sentry and capture_worker groups already exist and are unchanged." No
// `moved` block needed.

resource "aws_ssm_parameter" "capture_worker_shared_secret" {
  name  = "/${var.product}/capture_worker/shared_secret"
  type  = "SecureString"
  value = var.capture_worker_shared_secret
}

resource "aws_ssm_parameter" "capture_worker_demo_email" {
  name  = "/${var.product}/capture_worker/demo_email"
  type  = "String"
  value = var.capture_worker_demo_email
}

resource "aws_ssm_parameter" "capture_worker_demo_password" {
  name  = "/${var.product}/capture_worker/demo_password"
  type  = "SecureString"
  value = var.capture_worker_demo_password
}

// --- GitHub OAuth App ---

resource "aws_ssm_parameter" "auth_github_oauth_client_id" {
  name  = "/${var.product}/auth/github_oauth_client_id"
  type  = "String"
  value = var.auth_github_oauth_client_id
}

resource "aws_ssm_parameter" "auth_github_oauth_client_secret" {
  name  = "/${var.product}/auth/github_oauth_client_secret"
  type  = "SecureString"
  value = var.auth_github_oauth_client_secret
}
