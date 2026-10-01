// Sensitive variables backing user-populated aws_ssm_parameter.* resources in
// secrets.tf. Values are supplied via `secrets.auto.tfvars` (gitignored),
// rendered by `make secrets PRODUCT=aitravel` from env-registry.
// Rotations flow through `terraform apply` — do NOT use `aws ssm put-parameter`.

variable "auth_jwt_secret" {
  type      = string
  sensitive = true
}

// The iOS client signs in with email/password; no Google OAuth client is
// issued for aitravel. The server still requires both values at boot, so a
// non-empty placeholder is the documented state (README.md "Secrets").
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

variable "maps_places_api_key" {
  type        = string
  description = "Google Maps Platform Places API key (place enrichment)."
  sensitive   = true
}

variable "maps_routes_api_key" {
  type        = string
  description = "Google Maps Platform Routes API key (travel times between stops)."
  sensitive   = true
}
