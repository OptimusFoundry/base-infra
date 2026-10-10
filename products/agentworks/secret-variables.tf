// Sensitive variables backing user-populated aws_ssm_parameter.* resources in
// secrets.tf. Values are supplied via `secrets.auto.tfvars` (gitignored),
// rendered by `make secrets PRODUCT=agentworks` from env-registry.
// Rotations flow through `terraform apply` — do NOT use `aws ssm put-parameter`.

variable "auth_jwt_secret" {
  type      = string
  sensitive = true
}

// A real Google OAuth client, issued for agentworks. Its authorized redirect
// URIs must include https://agentworks.protoapp.xyz/api/auth/google/callback
// (the value of /agentworks/auth/google_redirect_uri).
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

variable "email_resend_webhook_secret" {
  type      = string
  sensitive = true
}

variable "email_sender_address" {
  type        = string
  description = "From-address on transactional email. The domain must be verified in Resend."
}

// HMAC key for hook and gateway tokens. The server refuses to boot without it
// outside dev/test. Generate fresh (`openssl rand -base64 48`); rotating it
// invalidates every outstanding hook token.
variable "gateway_token_key" {
  type      = string
  sensitive = true
}
