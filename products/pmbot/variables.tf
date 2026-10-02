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
  description = "Bootstrap image only (CH-008, EP-031): a git SHA whose five CI tags exist in ECR (<sha>-collect, <sha>-model, <sha>-trade, <sha>-research and <sha>). Each task definition family's Terraform-registered revision runs <sha>-<its target> (local.family_target). polymarket-bot's pmbot-deploy workflow registers every revision the services and the schedules run, and both ignore task-definition drift. Changing it replaces every task definition (a new revision, nothing running moves): bump it only to a SHA whose five tags exist."
  type        = string
  default     = "30baf6a6f7d42e0b317623d41009501c92740075"

  validation {
    condition     = can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$", var.image_tag)) && var.image_tag != "latest"
    error_message = "image_tag must be a non-empty, valid Docker tag and must not be \"latest\" (the repository is IMMUTABLE and deploys are pinned by git SHA)."
  }
}

variable "sports_s3_mode" {
  description = "SPORTS_S3 for every task: ro while the Mac recorder and maker still write the canonical prefix, rw after cutover (runbook). Default rw: the CH-007 cutover is done, so a CD apply must never flip the cloud back to ro."
  type        = string
  default     = "rw"

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
  description = "Exact OIDC sub claim allowed to assume the push role. Null derives repo:<github_repo>:ref:refs/heads/main. OptimusFoundry/polymarket-bot emits immutable subject claims (GET repos/OptimusFoundry/polymarket-bot/actions/oidc/customization/sub, 2026-10-01), so the default is that exact sub."
  type        = string
  default     = "repo:OptimusFoundry@167594521/polymarket-bot@1254825224:ref:refs/heads/main"
}

variable "data_bucket" {
  description = "The sports data bucket the task role reads and writes (created outside Terraform by EP-027)"
  type        = string
  default     = "polymarket-bot-data-339713122183"
}

variable "instance_type" {
  description = "Instance type of the dedicated pmbot ECS host (Graviton, arm64). t4g.xlarge (4 vCPU, 16 GiB) since EP-032: the per-family reservations in services.tf (polymarket-bot sports/ops/sizing.py) add up to 7,680 MiB and 3,200 CPU units with maker-live, more than a t4g.large (2,048 CPU units) holds. Changing it updates the launch template in place; it never replaces the running instance (replacing it is a runbook step, docs/runbooks/data-plane-compute.md in polymarket-bot)."
  type        = string
  default     = "t4g.xlarge"
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

variable "predictor_enabled" {
  description = "Whether the pmbot-predictor schedule (every 15 minutes, America/New_York) fires, and whether its two alarms exist (EP-030). Default false: the owner enables it by PR after one verified manual run (runbook docs/runbooks/predictor.md)."
  type        = bool
  default     = true
}

variable "base_infra_oidc_subject_prefix" {
  description = "OIDC sub prefix of OptimusFoundry/base-infra, which emits immutable subject claims (GET repos/OptimusFoundry/base-infra/actions/oidc/customization/sub, 2026-10-01). The apply role trusts <prefix>:ref:refs/heads/main, the plan role <prefix>:pull_request."
  type        = string
  default     = "repo:OptimusFoundry@167594521/base-infra@789290204"

  validation {
    condition     = can(regex("^repo:[^:]+$", var.base_infra_oidc_subject_prefix))
    error_message = "base_infra_oidc_subject_prefix must look like repo:<owner>/<name> (no ref suffix)."
  }
}
