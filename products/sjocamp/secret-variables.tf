// Sensitive variables backing user-populated aws_ssm_parameter.* resources in
// secrets.tf. Values are supplied via `secrets.auto.tfvars` (gitignored).
// Rotations flow through `terraform apply` — do NOT use `aws ssm put-parameter`.

variable "auth_jwt_secret" {
  type      = string
  sensitive = true
}

variable "auth_google_oauth_client_id" {
  type = string
}

variable "auth_google_oauth_client_secret" {
  type      = string
  sensitive = true
}

variable "payments_stripe_webhook_secret" {
  type      = string
  sensitive = true
}

variable "payments_stripe_billing_portal_config_id" {
  type        = string
  description = "Stripe Billing Portal configuration ID (bpc_*). Mode-specific — must be a live-mode config in production."
}

variable "email_resend_webhook_secret" {
  type      = string
  sensitive = true
}

variable "email_sender_address" {
  type = string
}

variable "sentry_webapp_dsn" {
  type        = string
  description = "Sentry DSN for the webapp project. Public (embedded in the client bundle) but managed in SSM for parity with other build-time config."
}

variable "sentry_auth_token" {
  type        = string
  sensitive   = true
  description = "Sentry CI auth token used by the webapp build to upload sourcemaps. Needs scopes: project:releases, project:write."
}
