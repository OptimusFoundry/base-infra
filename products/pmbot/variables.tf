variable "product" {
  description = "Product slug. Used for the Product tag; resource names are fixed to local.name (a rename would replace the ECR repository)."
  type        = string
  default     = "pmbot"
}

variable "aws_region" {
  description = "AWS region (must match platform)"
  type        = string
  default     = "us-east-1"
}

variable "cloudflare_email" {
  description = "Cloudflare account email, paired with the global API key from SSM /cloudflare/api_key. Set in the gitignored terraform.tfvars."
  type        = string
}

variable "image_tag" {
  description = "Bootstrap image only: a git SHA whose <sha>-collect, -model, -trade and -research tags exist in ECR. Each family's Terraform-registered revision runs <sha>-<target> (local.family_target). polymarket-bot's pmbot-deploy registers the revisions that actually run; services and schedules ignore task-definition drift. Changing this registers a new revision of every family and moves nothing running."
  type        = string
  default     = "6944a33fd59d36cb318962fb8325136bbb02782f"

  validation {
    condition     = can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$", var.image_tag)) && var.image_tag != "latest"
    error_message = "image_tag must be a valid Docker tag and not \"latest\" (the repository is IMMUTABLE and images are pinned by git SHA)."
  }
}

variable "sports_s3_mode" {
  description = "SPORTS_S3 for every task. rw: the cloud is the canonical writer. ro only for a rollback to the Mac writers."
  type        = string
  default     = "rw"

  validation {
    condition     = contains(["ro", "rw"], var.sports_s3_mode)
    error_message = "sports_s3_mode must be \"ro\" or \"rw\"."
  }
}

variable "github_repo" {
  description = "GitHub repository (owner/name) whose main branch may push images and deploy"
  type        = string
  default     = "OptimusFoundry/polymarket-bot"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "github_repo must look like owner/name."
  }
}

variable "github_oidc_subject" {
  description = "Exact OIDC sub claim allowed to assume the push and deploy roles. polymarket-bot emits immutable subject claims; null derives repo:<github_repo>:ref:refs/heads/main."
  type        = string
  default     = "repo:OptimusFoundry@167594521/polymarket-bot@1254825224:ref:refs/heads/main"
}

variable "data_bucket" {
  description = "The sports data bucket the task roles read and write (created outside Terraform)"
  type        = string
  default     = "polymarket-bot-data-339713122183"
}

variable "daily_ingest_enabled" {
  description = "Whether the 06:00 America/New_York daily-ingest schedule fires"
  type        = bool
  default     = true
}

variable "predictor_enabled" {
  description = "Whether the 15-minute predictor schedule fires, and whether its two alarms exist"
  type        = bool
  default     = true
}

variable "status_cost_source" {
  description = "Where the status page's cost panel gets its numbers (EP-035). estimate: pmbot's share of the shared platform host by reserved memory, at list price (no AWS call, no IAM). ce: that host share month to date plus Cost Explorer's actual for the Product=pmbot-tagged lines (the host is a platform resource and never carries the tag); needs the tag activated in the billing console and adds ce:GetCostAndUsage to the pmbot-status role. off: no cost panel."
  type        = string
  default     = "estimate"

  validation {
    condition     = contains(["off", "estimate", "ce"], var.status_cost_source)
    error_message = "status_cost_source must be \"off\", \"estimate\" or \"ce\"."
  }
}

variable "status_alarms_enabled" {
  description = "Whether the status-plane and collect-plane alarms exist (EP-035): pmbot-status-not-publishing and one pmbot-<tile>-data-stale per collector tile. Default false: pmbot-status may still be parked at desired 0, and a breaching StatusPublished alarm would sit in ALARM. Flip it by a one-line PR and an owner apply after the writer has published for 15 minutes (polymarket-bot docs/runbooks/ops.md). The log metric filters are always on."
  type        = bool
  default     = false
}
