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

variable "email_sender_address" {
  type = string
}

// --- Social platform + integration credentials ---

variable "social_x_api_key" {
  type      = string
  sensitive = true
}

variable "social_x_api_secret" {
  type      = string
  sensitive = true
}

variable "social_linkedin_client_id" {
  type = string
}

variable "social_linkedin_client_secret" {
  type      = string
  sensitive = true
}

variable "social_meta_app_id" {
  type = string
}

variable "social_meta_app_secret" {
  type      = string
  sensitive = true
}

variable "social_threads_app_id" {
  type = string
}

variable "social_threads_app_secret" {
  type      = string
  sensitive = true
}

variable "social_threads_access_token" {
  type      = string
  sensitive = true
}

variable "social_tiktok_client_key" {
  type = string
}

variable "social_tiktok_client_secret" {
  type      = string
  sensitive = true
}

variable "social_pinterest_app_id" {
  type = string
}

variable "social_pinterest_app_secret" {
  type      = string
  sensitive = true
}

variable "social_github_webhook_secret" {
  type      = string
  sensitive = true
}

// --- Media storage (bucket name, keys, public URL base) ---
//
// s3_bucket/s3_region/s3_access_key_id/s3_secret_access_key keep their bare
// names deliberately: they have no ssm path in the catalog (tf_products-only),
// so render-tfvars derives their tfvar name by stripping the domain prefix
// off the catalog name (STORAGE_S3_BUCKET -> s3_bucket) rather than from an
// ssm path — unlike storage_public_url_base below, which has an ssm path and
// so does carry the domain prefix.

variable "s3_bucket" {
  type = string
}

variable "s3_region" {
  type = string
}

variable "s3_access_key_id" {
  type      = string
  sensitive = true
}

variable "s3_secret_access_key" {
  type      = string
  sensitive = true
}

variable "storage_public_url_base" {
  type = string
}

// --- Capture worker ---

variable "capture_worker_shared_secret" {
  description = "Shared secret required on every request to the capture-worker via X-Capture-Secret header"
  type        = string
  sensitive   = true
}

variable "capture_worker_demo_email" {
  description = "Email of the seeded test-login user the capture-worker authenticates as"
  type        = string
}

variable "capture_worker_demo_password" {
  description = "Password of the seeded test-login user the capture-worker authenticates as"
  type        = string
  sensitive   = true
}

// --- GitHub OAuth App ---

variable "auth_github_oauth_client_id" {
  description = "Client ID of the GitHub OAuth App used for the Repos connection flow"
  type        = string
}

variable "auth_github_oauth_client_secret" {
  description = "Client secret of the GitHub OAuth App"
  type        = string
  sensitive   = true
}
