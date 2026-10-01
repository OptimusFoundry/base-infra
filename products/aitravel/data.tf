data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = "protoapp-infra-terraform-state"
    key    = "state/terraform.tfstate"
    region = var.aws_region
  }
}

# --- Platform-shared (account-wide secrets, single source of truth in /platform/*) ---
#
# Unlike orca, no RDS master credentials: aitravel connects as its own role
# (aitravel_app, see secrets.tf). openai/fal/elevenlabs are not read — the
# server uses Gemini only.

data "aws_ssm_parameter" "platform_resend_api_key" {
  name = "/platform/email/resend_api_key"
}

data "aws_ssm_parameter" "platform_gemini_api_key" {
  name = "/platform/ai/gemini_api_key"
}

data "aws_ssm_parameter" "platform_stripe_secret_key" {
  name = "/platform/payments/stripe_secret_key"
}

data "aws_ssm_parameter" "rds_host" {
  name = "/platform/rds/host"
}

data "aws_ssm_parameter" "rds_port" {
  name = "/platform/rds/port"
}

# --- Product-owned (per-product secrets) ---
#
# Read back through data sources so the task definition consumes the resolved
# SSM value rather than the variable, keeping one source of truth per secret.

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

data "aws_ssm_parameter" "payments_stripe_webhook_secret" {
  name       = aws_ssm_parameter.payments_stripe_webhook_secret.name
  depends_on = [aws_ssm_parameter.payments_stripe_webhook_secret]
}

data "aws_ssm_parameter" "email_resend_webhook_secret" {
  name       = aws_ssm_parameter.email_resend_webhook_secret.name
  depends_on = [aws_ssm_parameter.email_resend_webhook_secret]
}

data "aws_ssm_parameter" "email_sender_address" {
  name       = aws_ssm_parameter.email_sender_address.name
  depends_on = [aws_ssm_parameter.email_sender_address]
}

data "aws_ssm_parameter" "maps_places_api_key" {
  name       = aws_ssm_parameter.maps_places_api_key.name
  depends_on = [aws_ssm_parameter.maps_places_api_key]
}

data "aws_ssm_parameter" "maps_routes_api_key" {
  name       = aws_ssm_parameter.maps_routes_api_key.name
  depends_on = [aws_ssm_parameter.maps_routes_api_key]
}
