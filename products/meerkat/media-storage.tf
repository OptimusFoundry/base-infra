# Shared S3 bucket + IAM user for media uploads. Used by all products via the
# /platform/storage/* SSM params. Bucket existed before this was TF-managed
# (created manually for local dev); the import blocks adopt it on apply without
# recreation.

# ---------- Bucket ----------

import {
  to = aws_s3_bucket.media
  id = "growth-tools-media-dev"
}

resource "aws_s3_bucket" "media" {
  bucket = "growth-tools-media-dev"
}

import {
  to = aws_s3_bucket_ownership_controls.media
  id = "growth-tools-media-dev"
}

resource "aws_s3_bucket_ownership_controls" "media" {
  bucket = aws_s3_bucket.media.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

import {
  to = aws_s3_bucket_public_access_block.media
  id = "growth-tools-media-dev"
}

# Public-by-design: served via MEDIA_PUBLIC_URL_BASE in the app. Bucket policy
# below grants s3:GetObject to everyone; all block-public flags must be false.
resource "aws_s3_bucket_public_access_block" "media" {
  bucket                  = aws_s3_bucket.media.id
  block_public_acls       = false
  ignore_public_acls      = false
  block_public_policy     = false
  restrict_public_buckets = false
}

import {
  to = aws_s3_bucket_policy.media
  id = "growth-tools-media-dev"
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

import {
  to = aws_s3_bucket_server_side_encryption_configuration.media
  id = "growth-tools-media-dev"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "media" {
  bucket = aws_s3_bucket.media.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = false
  }
}

import {
  to = aws_s3_bucket_cors_configuration.media
  id = "growth-tools-media-dev"
}

# Current CORS is read-only (GET/HEAD from any origin). Matches the existing
# config. If/when you start uploading directly from the browser (presigned
# URLs), extend allowed_methods to include PUT/POST and narrow allowed_origins
# to the product domains.
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

import {
  to = aws_iam_user.media_uploader
  id = "growth-tools-media-dev"
}

resource "aws_iam_user" "media_uploader" {
  name = "growth-tools-media-dev"
  path = "/"
}

import {
  to = aws_iam_user_policy.media_uploader_s3_access
  id = "growth-tools-media-dev:s3-media-access"
}

resource "aws_iam_user_policy" "media_uploader_s3_access" {
  name = "s3-media-access"
  user = aws_iam_user.media_uploader.name
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

import {
  to = aws_iam_access_key.media_uploader
  id = "AKIAU6GD236DSUNOARFJ"
}

# The secret was visible only at creation time. Terraform imports the public
# attributes (id, status, create_date) but `secret` stays unknown. The app
# reaches the container as the S3_SECRET_ACCESS_KEY (or STORAGE_S3_SECRET_
# ACCESS_KEY, for base-server) env var, injected by Terraform from
# aws_ssm_parameter.storage_s3_secret_access_key (populated from
# secrets.auto.tfvars). The container has no task role and never calls SSM
# itself. Re-seed the tfvars + apply if the access key is ever rotated.
resource "aws_iam_access_key" "media_uploader" {
  user = aws_iam_user.media_uploader.name
}

# ---------- SSM config read by the app at container start ----------
#
# s3_bucket/s3_region/s3_access_key_id/s3_secret_access_key keep their bare
# Terraform resource labels and ssm paths — they have no ssm path in the
# env-registry catalog (tf_products-only), so render-tfvars derives their
# tfvar name by stripping the domain prefix off the catalog name
# (STORAGE_S3_BUCKET -> s3_bucket), not from an ssm path. Only the app-facing
# env var name changes (see ecs-service.tf); nothing here moves.
#
# media_public_url_base DOES have an ssm path, so its derived name carries
# the domain prefix — see the `moved` block below.

moved {
  from = aws_ssm_parameter.media_public_url_base
  to   = aws_ssm_parameter.storage_public_url_base
}

resource "aws_ssm_parameter" "s3_bucket" {
  name  = "/${var.product}/storage/s3_bucket"
  type  = "String"
  value = var.s3_bucket
}

resource "aws_ssm_parameter" "s3_region" {
  name  = "/${var.product}/storage/s3_region"
  type  = "String"
  value = var.s3_region
}

resource "aws_ssm_parameter" "s3_access_key_id" {
  name  = "/${var.product}/storage/s3_access_key_id"
  type  = "SecureString"
  value = var.s3_access_key_id
}

resource "aws_ssm_parameter" "s3_secret_access_key" {
  name  = "/${var.product}/storage/s3_secret_access_key"
  type  = "SecureString"
  value = var.s3_secret_access_key
}

// Leaf shortened from media_public_url_base to public_url_base to match
// env-registry's catalog (STORAGE_PUBLIC_URL_BASE). See orca's
// media-storage.tf for the equivalent rename.
resource "aws_ssm_parameter" "storage_public_url_base" {
  name  = "/${var.product}/storage/public_url_base"
  type  = "String"
  value = var.storage_public_url_base
}
