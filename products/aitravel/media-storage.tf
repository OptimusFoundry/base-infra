# S3 bucket + IAM user for uploaded media.
#
# PRIVATE, unlike orca's public-read equivalent. The only uploads today are
# booking screenshots (base-server booking processor, key
# `orphans/<user>/<uuid>`): personal data whose URL is never returned to
# clients. So: all four public-access-block flags on, no public-read bucket
# policy, no CORS.
#
# As in orca, nothing here is imported — the bucket and key are created by this
# stack, so `aws_iam_access_key.media.secret` is known to Terraform and feeds
# the task definition directly. Rotation is `terraform taint` + apply.

resource "aws_s3_bucket" "media" {
  bucket = var.media_bucket_name
}

resource "aws_s3_bucket_ownership_controls" "media" {
  bucket = aws_s3_bucket.media.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "media" {
  bucket                  = aws_s3_bucket.media.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "media" {
  bucket = aws_s3_bucket.media.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ---------- IAM user + inline policy + access key ----------
#
# A user with a static key rather than the ECS task role, because base-server
# takes S3 credentials as explicit env vars (STORAGE_S3_ACCESS_KEY_ID /
# STORAGE_S3_SECRET_ACCESS_KEY) rather than resolving them from the instance
# metadata chain.

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
# The task definition reads the resources directly, not these parameters;
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

# base-server's config requires STORAGE_PUBLIC_URL_BASE whenever STORAGE_TYPE=s3,
# so it keeps orca's value. The bucket is private, so URLs built from it are not
# fetchable anonymously — nothing returns them to clients today.
resource "aws_ssm_parameter" "storage_public_url_base" {
  name  = "/${var.product}/storage/public_url_base"
  type  = "String"
  value = "https://${aws_s3_bucket.media.id}.s3.${var.aws_region}.amazonaws.com"
}
