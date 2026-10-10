variable "product" {
  description = "Product identifier (used in resource names and SSM paths)"
  type        = string
  default     = "sjocamp"
}

variable "domain_name" {
  description = "Domain served by this product (app subdomain — landing site lives at the apex)"
  type        = string
  default     = "app.sjocamp.co"
}

variable "aws_region" {
  description = "AWS region (must match platform)"
  type        = string
  default     = "us-east-1"
}

variable "display_name" {
  description = "Human-facing product name (used in the SSM manifest the app repo reads)"
  type        = string
  default     = "Sjocamp"
}

variable "landing_domain" {
  description = "Apex domain that serves the marketing landing page"
  type        = string
  default     = "sjocamp.co"
}

variable "cloudflare_email" {
  description = "Cloudflare account email"
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for sjocamp.co"
  type        = string
  default     = "858e1079c9f3cfa804a258e78b2f02ed"
}

variable "environment" {
  description = "GO_ENV value for the API container"
  type        = string
  default     = "production"
}

variable "alb_rule_priority" {
  description = "Priority for this product's ALB listener rule. Must be unique across products."
  type        = number
  default     = 100
}

variable "container_name_api" {
  description = "Container name in the API task definition"
  type        = string
  default     = "api"
}

variable "service_name_api" {
  description = "ECS service name"
  type        = string
  default     = "sjocamp-api"
}

variable "api_image_tag" {
  description = "ECR image tag to deploy"
  type        = string
  default     = "latest"
}

variable "ecr_repository_name" {
  description = "ECR repository name for this product's API image (Terraform-managed; see ecr.tf)"
  type        = string
  default     = "sjocamp-server"
}

// Rightsized 2026-04-16: the Go binary sits at ~10 MB RSS and <1% of 1 vCPU
// under current load; previous defaults (256/256) were ~150x overprovisioned.

variable "api_container_cpu" {
  description = "CPU shares (weight) for the API container"
  type        = number
  default     = 64
}

variable "api_container_memory_reservation" {
  description = "Soft memory reservation (MB) — used for ECS scheduling"
  type        = number
  default     = 48
}

variable "api_container_memory" {
  description = "Hard memory cap (MB) — container killed if exceeded"
  type        = number
  default     = 128
}

variable "sentry_org" {
  description = "Sentry organisation slug (used by the webapp build to upload sourcemaps)."
  type        = string
}

variable "sentry_webapp_project" {
  description = "Sentry project slug for the webapp."
  type        = string
}

variable "api_desired_count" {
  description = "Number of API tasks to run"
  type        = number
  default     = 1
}

# --- Migrator (one-shot Flyway task, run by CI with `ecs run-task`; migrator.tf) ---

variable "migrator_ecr_repository_name" {
  description = "ECR repository name for the Flyway migrator image (Terraform-managed; see migrator.tf)"
  type        = string
  default     = "sjocamp-migrator"
}

variable "migrator_image_tag" {
  description = "ECR image tag for the migrator task"
  type        = string
  default     = "latest"
}

# Flyway is a JVM: it needs more memory than the Go server, but runs for seconds
# and exits before the API deploy starts.
variable "migrator_container_cpu" {
  description = "CPU shares (weight) for the migrator container"
  type        = number
  default     = 64
}

variable "migrator_container_memory_reservation" {
  description = "Soft memory reservation (MB) for the migrator container"
  type        = number
  default     = 512
}

variable "migrator_container_memory" {
  description = "Hard memory cap (MB) for the migrator container"
  type        = number
  default     = 1024
}
