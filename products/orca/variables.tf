variable "product" {
  description = "Product slug — used in resource names, SSM paths and the X-Product-Id routing header"
  type        = string
  default     = "orca"
}

variable "domain_name" {
  description = "Domain served by this product"
  type        = string
  default     = "orca.protoapp.xyz"
}

variable "aws_region" {
  description = "AWS region (must match platform)"
  type        = string
  default     = "us-east-1"
}

variable "display_name" {
  description = "Human-facing product name (used in the SSM manifest the app repo reads)"
  type        = string
  default     = "TickUpToks"
}

variable "landing_domain" {
  description = "Domain serving the marketing landing page. orca has no separate landing — same as app."
  type        = string
  default     = "orca.protoapp.xyz"
}

variable "cloudflare_email" {
  description = "Cloudflare account email, paired with the global API key from SSM /cloudflare/api_key. Set in the gitignored terraform.tfvars."
  type        = string
}

variable "environment" {
  description = "GO_ENV value for the API container"
  type        = string
  default     = "production"
}

variable "alb_rule_priority" {
  description = "Priority for this product's ALB listener rule. Must be unique across products."
  type        = number
  default     = 300
}

# --- API service ---

variable "container_name_api" {
  description = "Container name in the API task definition"
  type        = string
  default     = "api"
}

variable "service_name_api" {
  description = "ECS service name for the API"
  type        = string
  default     = "orca-api"
}

variable "api_image_tag" {
  description = "ECR image tag to deploy"
  type        = string
  default     = "latest"
}

variable "ecr_repository_name" {
  description = "ECR repository name for this product's API image (Terraform-managed; see ecr.tf)"
  type        = string
  default     = "orca-server"
}

# Sized against sjocamp's measured Go footprint (~10 MB RSS, <1% of 1 vCPU),
# with extra headroom because orca runs the content-job pipeline in-process.
variable "api_container_cpu" {
  description = "CPU shares (weight) for the API container"
  type        = number
  default     = 128
}

variable "api_container_memory_reservation" {
  description = "Soft memory reservation (MB) — used for ECS scheduling"
  type        = number
  default     = 128
}

variable "api_container_memory" {
  description = "Hard memory cap (MB) — container killed if exceeded"
  type        = number
  default     = 384
}

variable "api_desired_count" {
  description = "Number of API tasks to run"
  type        = number
  default     = 1
}

# --- Render service ---

variable "render_service_ecr_repository" {
  description = "ECR repository holding the render-service image"
  type        = string
  default     = "orca-render-service"
}

variable "render_service_name" {
  description = "ECS service name for the render-service"
  type        = string
  default     = "orca-render-service"
}

variable "render_service_container_name" {
  description = "Container name in the render-service task definition"
  type        = string
  default     = "render-service"
}

variable "render_service_image_tag" {
  description = "ECR image tag to deploy for the render-service"
  type        = string
  default     = "latest"
}

# Remotion drives headless Chromium and composites video frames — the heaviest
# thing on this cluster. Soft reservation only (no hard `memory` cap): the ECS
# host has ~5 GB free, and a hard cap that Chromium briefly exceeds kills the
# render mid-job rather than slowing it down.
variable "render_service_cpu" {
  description = "CPU shares (weight) for the render-service container"
  type        = number
  default     = 512
}

variable "render_service_memory_reservation" {
  description = "Soft memory reservation (MB) for the render-service container"
  type        = number
  default     = 1536
}

variable "render_service_desired_count" {
  description = "Number of render-service tasks to run"
  type        = number
  default     = 1
}

# --- Media storage ---

variable "media_bucket_name" {
  description = "S3 bucket holding generated media. Public-read by design — the app serves fetchable URLs from it."
  type        = string
  default     = "protoapp-orca-media"
}

# --- Migrator (one-shot Flyway task, run by CI with `ecs run-task`; migrator.tf) ---

variable "migrator_ecr_repository_name" {
  description = "ECR repository name for the Flyway migrator image (Terraform-managed; see migrator.tf)"
  type        = string
  default     = "orca-migrator"
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
