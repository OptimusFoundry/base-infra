variable "product" {
  description = "Product identifier (used in resource names, SSM paths and the X-Product-Id header)"
  type        = string
  default     = "meerkat"
}

variable "domain_name" {
  description = "Domain served by this product"
  type        = string
  default     = "meerkat.protoapp.xyz"
}

variable "aws_region" {
  description = "AWS region (must match platform)"
  type        = string
  default     = "us-east-1"
}

variable "display_name" {
  description = "Human-facing product name (used in the SSM manifest the app repo reads)"
  type        = string
  default     = "Meerkat"
}

variable "landing_domain" {
  description = "Domain serving this product (meerkat has no separate landing — same as app)"
  type        = string
  default     = "meerkat.protoapp.xyz"
}

variable "cloudflare_email" {
  description = "Cloudflare account email"
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for protoapp.xyz"
  type        = string
  default     = "e1fcf5e6c9b60043f75049228a8e3088"
}

variable "environment" {
  description = "GO_ENV value for the API container"
  type        = string
  default     = "production"
}

variable "container_name_api" {
  description = "Container name in the API task definition"
  type        = string
  default     = "api"
}

variable "service_name_api" {
  description = "ECS service name"
  type        = string
  default     = "api_service"
}

variable "api_image_tag" {
  description = "ECR image tag to deploy"
  type        = string
  default     = "latest"
}

variable "ecr_repository_name" {
  description = "ECR repository holding the API image"
  type        = string
  default     = "base-server"
}

# Deliberately NOT renamed to meerkat-capture-worker. ECR repository names are
# ForceNew: renaming destroys the repository and every image in it, leaving the
# capture worker undeployable until CI pushes a fresh image. The name is
# internal and invisible to users, so the rename buys nothing.
variable "capture_worker_ecr_repository" {
  description = "ECR repository holding the capture-worker image. Keeps the protoapp- prefix on purpose; see comment above."
  type        = string
  default     = "protoapp-capture-worker"
}

variable "capture_worker_service_name" {
  description = "ECS service name for the capture-worker"
  type        = string
  default     = "capture_worker_service"
}

variable "capture_worker_container_name" {
  description = "Container name in the capture-worker task definition"
  type        = string
  default     = "capture-worker"
}

variable "capture_worker_image_tag" {
  description = "ECR image tag to deploy for the capture-worker"
  type        = string
  default     = "latest"
}

# --- Migrator (one-shot Flyway task, run by CI with `ecs run-task`; migrator.tf) ---

variable "migrator_ecr_repository_name" {
  description = "ECR repository name for the Flyway migrator image (Terraform-managed; see migrator.tf)"
  type        = string
  default     = "meerkat-migrator"
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
