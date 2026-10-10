data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = "protoapp-infra-terraform-state"
    key    = "state/terraform.tfstate"
    region = var.aws_region
  }
}

data "aws_caller_identity" "current" {}

# --- Platform-shared (account-wide secrets, single source of truth in /platform/*) ---
#
# As in aitravel, no RDS master credentials: agentworks connects as its own
# role (agentworks_app, see secrets.tf). No AI keys — the server reads none;
# Claude logins are OAuth tokens stored in its database.

data "aws_ssm_parameter" "platform_resend_api_key" {
  name = "/platform/email/resend_api_key"
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

data "aws_ssm_parameter" "gateway_token_key" {
  name       = aws_ssm_parameter.gateway_token_key.name
  depends_on = [aws_ssm_parameter.gateway_token_key]
}
