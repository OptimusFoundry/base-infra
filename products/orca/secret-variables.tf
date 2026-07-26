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
  description = "Stripe Billing Portal configuration ID (bpc_*). Mode-specific — must be a live-mode config in production. Empty falls back to the account default."
  default     = ""
}

variable "email_resend_webhook_secret" {
  type      = string
  sensitive = true
}

variable "email_sender_address" {
  type        = string
  description = "From-address on transactional email. The domain must be verified in Resend."
}

// --- Sentry (stubbed) ---
//
// orca is not wired to Sentry yet. These exist so adding it later is a value
// edit in env-registry plus `make secrets PRODUCT=orca` — no Terraform change.
// Empty is the documented "not configured" state: secrets.tf omits the SSM
// parameter entirely rather than storing "", which SSM rejects anyway.

variable "sentry_webapp_dsn" {
  type        = string
  description = "Sentry DSN for webapp runtime errors. Empty means Sentry is not wired up."
  default     = ""
}

variable "sentry_auth_token" {
  type        = string
  description = "CI credential that uploads sourcemaps during build."
  sensitive   = true
  default     = ""
}

variable "sentry_org" {
  type        = string
  description = "Sentry organisation slug, consumed by the SSM manifest."
  default     = ""
}

variable "sentry_webapp_project" {
  type        = string
  description = "Sentry project slug for the webapp, consumed by the SSM manifest."
  default     = ""
}
