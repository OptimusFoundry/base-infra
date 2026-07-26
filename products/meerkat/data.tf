data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = "protoapp-infra-terraform-state"
    key    = "state/terraform.tfstate"
    region = var.aws_region
  }
}

data "aws_ecr_repository" "api" {
  name = var.ecr_repository_name
}

# --- Platform-shared (account-wide secrets, single source of truth in /platform/*) ---

data "aws_ssm_parameter" "rds_host" {
  name = "/platform/rds/host"
}

data "aws_ssm_parameter" "rds_port" {
  name = "/platform/rds/port"
}

data "aws_ssm_parameter" "platform_db_username" {
  name = "/platform/rds/master_username"
}

data "aws_ssm_parameter" "platform_db_password" {
  name = "/platform/rds/master_password"
}

data "aws_ssm_parameter" "platform_resend_api_key" {
  name = "/platform/email/resend_api_key"
}

data "aws_ssm_parameter" "platform_openai_api_key" {
  name = "/platform/ai/openai_api_key"
}

data "aws_ssm_parameter" "platform_gemini_api_key" {
  name = "/platform/ai/gemini_api_key"
}

data "aws_ssm_parameter" "platform_stripe_secret_key" {
  name = "/platform/payments/stripe_secret_key"
}

data "aws_ssm_parameter" "platform_turnstile_secret_key" {
  name = "/platform/auth/turnstile_secret_key"
}

# --- Product-owned (per-product secrets) ---

data "aws_ssm_parameter" "db_name" {
  name       = aws_ssm_parameter.db_name.name
  depends_on = [aws_ssm_parameter.db_name]
}

data "aws_ssm_parameter" "auth_jwt_secret" {
  name       = aws_ssm_parameter.auth_jwt_secret.name
  depends_on = [aws_ssm_parameter.auth_jwt_secret]
}

data "aws_ssm_parameter" "auth_google_oauth_client_id" {
  name       = aws_ssm_parameter.auth_google_oauth_client_id.name
  depends_on = [aws_ssm_parameter.auth_google_oauth_client_id]
}

data "aws_ssm_parameter" "auth_google_oauth_client_secret" {
  name       = aws_ssm_parameter.auth_google_oauth_client_secret.name
  depends_on = [aws_ssm_parameter.auth_google_oauth_client_secret]
}

data "aws_ssm_parameter" "auth_google_redirect_uri" {
  name       = aws_ssm_parameter.auth_google_redirect_uri.name
  depends_on = [aws_ssm_parameter.auth_google_redirect_uri]
}

data "aws_ssm_parameter" "app_webapp_uri" {
  name       = aws_ssm_parameter.app_webapp_uri.name
  depends_on = [aws_ssm_parameter.app_webapp_uri]
}

data "aws_ssm_parameter" "payments_stripe_webhook_secret" {
  name       = aws_ssm_parameter.payments_stripe_webhook_secret.name
  depends_on = [aws_ssm_parameter.payments_stripe_webhook_secret]
}

data "aws_ssm_parameter" "email_sender_address" {
  name       = aws_ssm_parameter.email_sender_address.name
  depends_on = [aws_ssm_parameter.email_sender_address]
}

# --- Social platform + integration credentials ---

data "aws_ssm_parameter" "social_x_api_key" {
  name       = aws_ssm_parameter.social_x_api_key.name
  depends_on = [aws_ssm_parameter.social_x_api_key]
}

data "aws_ssm_parameter" "social_x_api_secret" {
  name       = aws_ssm_parameter.social_x_api_secret.name
  depends_on = [aws_ssm_parameter.social_x_api_secret]
}

data "aws_ssm_parameter" "social_linkedin_client_id" {
  name       = aws_ssm_parameter.social_linkedin_client_id.name
  depends_on = [aws_ssm_parameter.social_linkedin_client_id]
}

data "aws_ssm_parameter" "social_linkedin_client_secret" {
  name       = aws_ssm_parameter.social_linkedin_client_secret.name
  depends_on = [aws_ssm_parameter.social_linkedin_client_secret]
}

data "aws_ssm_parameter" "social_meta_app_id" {
  name       = aws_ssm_parameter.social_meta_app_id.name
  depends_on = [aws_ssm_parameter.social_meta_app_id]
}

data "aws_ssm_parameter" "social_meta_app_secret" {
  name       = aws_ssm_parameter.social_meta_app_secret.name
  depends_on = [aws_ssm_parameter.social_meta_app_secret]
}

data "aws_ssm_parameter" "social_threads_app_id" {
  name       = aws_ssm_parameter.social_threads_app_id.name
  depends_on = [aws_ssm_parameter.social_threads_app_id]
}

data "aws_ssm_parameter" "social_threads_app_secret" {
  name       = aws_ssm_parameter.social_threads_app_secret.name
  depends_on = [aws_ssm_parameter.social_threads_app_secret]
}

data "aws_ssm_parameter" "social_threads_access_token" {
  name       = aws_ssm_parameter.social_threads_access_token.name
  depends_on = [aws_ssm_parameter.social_threads_access_token]
}

data "aws_ssm_parameter" "social_tiktok_client_key" {
  name       = aws_ssm_parameter.social_tiktok_client_key.name
  depends_on = [aws_ssm_parameter.social_tiktok_client_key]
}

data "aws_ssm_parameter" "social_tiktok_client_secret" {
  name       = aws_ssm_parameter.social_tiktok_client_secret.name
  depends_on = [aws_ssm_parameter.social_tiktok_client_secret]
}

data "aws_ssm_parameter" "social_pinterest_app_id" {
  name       = aws_ssm_parameter.social_pinterest_app_id.name
  depends_on = [aws_ssm_parameter.social_pinterest_app_id]
}

data "aws_ssm_parameter" "social_pinterest_app_secret" {
  name       = aws_ssm_parameter.social_pinterest_app_secret.name
  depends_on = [aws_ssm_parameter.social_pinterest_app_secret]
}

data "aws_ssm_parameter" "social_github_webhook_secret" {
  name       = aws_ssm_parameter.social_github_webhook_secret.name
  depends_on = [aws_ssm_parameter.social_github_webhook_secret]
}

data "aws_ssm_parameter" "auth_oauth_redirect_base" {
  name       = aws_ssm_parameter.auth_oauth_redirect_base.name
  depends_on = [aws_ssm_parameter.auth_oauth_redirect_base]
}

data "aws_ssm_parameter" "storage_type" {
  name       = aws_ssm_parameter.storage_type.name
  depends_on = [aws_ssm_parameter.storage_type]
}
