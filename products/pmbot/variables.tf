variable "product" {
  description = "Product slug. Used for the Product tag only: resource names are fixed to local.name (a rename would replace the ECR repository)."
  type        = string
  default     = "pmbot"
}

variable "aws_region" {
  description = "AWS region (must match platform)"
  type        = string
  default     = "us-east-1"
}

variable "image_tag" {
  description = "ECR image tag every task definition runs. No default on purpose: a deploy is the owner setting this to the git SHA CI pushed, then applying a saved plan. A rollback is the previous SHA."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$", var.image_tag)) && var.image_tag != "latest"
    error_message = "image_tag must be a non-empty, valid Docker tag and must not be \"latest\" (the repository is IMMUTABLE and deploys are pinned by git SHA)."
  }
}

variable "sports_s3_mode" {
  description = "SPORTS_S3 for every task: ro while the Mac recorder and maker still write the canonical prefix, rw after cutover (runbook)."
  type        = string
  default     = "ro"

  validation {
    condition     = contains(["ro", "rw"], var.sports_s3_mode)
    error_message = "sports_s3_mode must be \"ro\" or \"rw\"."
  }
}

variable "github_repo" {
  description = "GitHub repository (owner/name) whose main branch may push images to ECR"
  type        = string
  default     = "OptimusFoundry/polymarket-bot"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "github_repo must look like owner/name."
  }
}

variable "github_oidc_subject" {
  description = "Exact OIDC sub claim allowed to assume the push role. Null derives repo:<github_repo>:ref:refs/heads/main. Set it only if the org emits immutable subject claims (repo:OWNER@ID/REPO@ID:ref:refs/heads/main)."
  type        = string
  default     = null
}

variable "data_bucket" {
  description = "The sports data bucket the task role reads and writes (created outside Terraform by EP-027)"
  type        = string
  default     = "polymarket-bot-data-339713122183"
}

variable "instance_type" {
  description = "Instance type of the dedicated pmbot ECS host (Graviton, arm64)"
  type        = string
  default     = "t4g.large"
}

variable "root_volume_gb" {
  description = "Root volume size in GB; /data lives on it. The AMI snapshot is 30 GB, so the floor is 30."
  type        = number
  default     = 100

  validation {
    condition     = var.root_volume_gb >= 30
    error_message = "root_volume_gb must be at least 30 (the AMI snapshot size)."
  }
}

variable "daily_ingest_enabled" {
  description = "Whether the 06:00 America/New_York daily-ingest schedule fires (runbook rollback switch)"
  type        = bool
  default     = true
}
