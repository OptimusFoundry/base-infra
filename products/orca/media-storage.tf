# S3 bucket + IAM user for generated media (images, audio, rendered video).
# Both the API and the render-service write here; the app serves fetchable URLs
# straight off the bucket via MEDIA_PUBLIC_URL_BASE.
#
# Unlike meerkat's equivalent, nothing here is imported — the bucket and key are
# created by this stack, so `aws_iam_access_key.media.secret` is known to
# Terraform and feeds the task definitions directly. No tfvars round-trip, and
# rotation is `terraform taint` + apply rather than a manual re-seed.

resource "aws_s3_bucket" "media" {
  bucket = var.media_bucket_name
}

resource "aws_s3_bucket_ownership_controls" "media" {
  bucket = aws_s3_bucket.media.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Public-by-design: the app hands out MEDIA_PUBLIC_URL_BASE URLs that external
# platforms fetch directly. The bucket policy below grants s3:GetObject to
# everyone, so all four block-public flags must be false or the policy is inert.
resource "aws_s3_bucket_public_access_block" "media" {
  bucket                  = aws_s3_bucket.media.id
  block_public_acls       = false
  ignore_public_acls      = false
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "media" {
  bucket = aws_s3_bucket.media.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadGetObject"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.media.arn}/*"
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.media]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "media" {
  bucket = aws_s3_bucket.media.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_cors_configuration" "media" {
  bucket = aws_s3_bucket.media.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = ["*"]
    max_age_seconds = 3000
  }
}

# ---------- IAM user + inline policy + access key ----------
#
# A user with a static key rather than the ECS task role, because the app takes
# S3 credentials as explicit env vars (S3_ACCESS_KEY_ID/S3_SECRET_ACCESS_KEY in
# base-server, the SDK-standard AWS_* pair in render-service) rather than
# resolving them from the instance metadata chain.

resource "aws_iam_user" "media" {
  name = var.media_bucket_name
  path = "/"
}

resource "aws_iam_user_policy" "media" {
  name = "s3-media-access"
  user = aws_iam_user.media.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "BucketObjectAccess"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.media.arn}/*"
      },
      {
        Sid      = "BucketList"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.media.arn
      }
    ]
  })
}

resource "aws_iam_access_key" "media" {
  user = aws_iam_user.media.name
}

# ---------- SSM config read by CI and for out-of-band debugging ----------
#
# The task definitions below read the resources directly, not these parameters;
# these exist so the values are inspectable without terraform state access.

resource "aws_ssm_parameter" "s3_bucket" {
  name  = "/${var.product}/storage/s3_bucket"
  type  = "String"
  value = aws_s3_bucket.media.id
}

resource "aws_ssm_parameter" "s3_region" {
  name  = "/${var.product}/storage/s3_region"
  type  = "String"
  value = var.aws_region
}

resource "aws_ssm_parameter" "s3_access_key_id" {
  name  = "/${var.product}/storage/s3_access_key_id"
  type  = "SecureString"
  value = aws_iam_access_key.media.id
}

resource "aws_ssm_parameter" "s3_secret_access_key" {
  name  = "/${var.product}/storage/s3_secret_access_key"
  type  = "SecureString"
  value = aws_iam_access_key.media.secret
}

// Leaf shortened from media_public_url_base to public_url_base to match
// env-registry's catalog (STORAGE_PUBLIC_URL_BASE). See secrets.tf's header
// comment on the env-var-rename in general.
moved {
  from = aws_ssm_parameter.media_public_url_base
  to   = aws_ssm_parameter.storage_public_url_base
}

resource "aws_ssm_parameter" "storage_public_url_base" {
  name  = "/${var.product}/storage/public_url_base"
  type  = "String"
  value = "https://${aws_s3_bucket.media.id}.s3.${var.aws_region}.amazonaws.com"
}
