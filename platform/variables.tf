variable "aws_region" {
  description = "AWS region for all platform resources"
  type        = string
  default     = "us-east-1"
}

variable "cloudflare_email" {
  description = "Cloudflare account email (paired with the global API key from /cloudflare/api_key)"
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for the umbrella zone (protoapp.xyz)"
  type        = string
  default     = "e1fcf5e6c9b60043f75049228a8e3088"
}

variable "zone_domain" {
  description = "Umbrella domain hosting all product subdomains"
  type        = string
  default     = "protoapp.xyz"
}

# GitHub Actions OIDC subject patterns allowed to assume the deploy role.
#
# The `owner@ID/repo@ID` entries are NOT redundant with the plain ones. GitHub
# switched to immutable subject claims that embed owner and repository IDs
# (https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/):
# every repository created, renamed or transferred on or after 2026-07-15 emits
#
#   repo:SAVentures@167594521/tickuptoks@1312020530:ref:refs/heads/main
#
# which `repo:SAVentures/*` cannot match — the character after the org name is
# `@`, not `/`. Repos predating the cutoff keep the old format, so both forms
# have to be listed until every repository has rolled over.
#
# DMSAVentures is the org's former name and no longer resolves on GitHub; its
# entry is left alone rather than cleaned up here, because removing a trust
# subject is a security change that deserves its own review.
variable "github_oidc_allowed_subjects" {
  description = "sub claim patterns permitted to assume github-actions-admin-aws"
  type        = list(string)
  default = [
    "repo:DMSAVentures/*",
    "repo:SAVentures/*",
    "repo:SAVentures@167594521/*",
    # AITravel's server deploy (aitravel-server.yml). Deliberately narrower than
    # the org-wide entries above: one repo, main only, immutable-subject form
    # (repo created after the cutoff; IDs from `gh api repos/OptimusFoundry/AITravel`).
    "repo:OptimusFoundry@167594521/AITravel@1312039071:ref:refs/heads/main",
  ]
}

variable "ecs_instance_type" {
  description = "Instance type of the single shared ECS host (Graviton/arm64). Changing it updates the launch template; the running host is only replaced when terminated."
  type        = string
  default     = "t4g.2xlarge"
}

variable "ecs_root_volume_gb" {
  description = "Root volume of the shared ECS host. Holds every product's images and pmbot's data volumes; the AMI snapshot floor is 30."
  type        = number
  default     = 100

  validation {
    condition     = var.ecs_root_volume_gb >= 30
    error_message = "ecs_root_volume_gb must be at least 30 (the AMI snapshot size)."
  }
}
