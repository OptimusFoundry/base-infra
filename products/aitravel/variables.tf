variable "product" {
  description = "Product slug — used in resource names, SSM paths and the X-Product-Id routing header"
  type        = string
  default     = "aitravel"
}

variable "domain_name" {
  description = "Domain served by this product"
  type        = string
  default     = "aitravel.protoapp.xyz"
}

variable "aws_region" {
  description = "AWS region (must match platform)"
  type        = string
  default     = "us-east-1"
}

variable "display_name" {
  description = "Human-facing product name (used in the SSM manifest the app repo reads)"
  type        = string
  default     = "AITravel"
}

variable "landing_domain" {
  description = "Domain serving the marketing landing page. aitravel has no separate landing on AWS — same as app."
  type        = string
  default     = "aitravel.protoapp.xyz"
}

variable "cloudflare_email" {
  description = "Cloudflare account email, paired with the global API key from SSM /cloudflare/api_key. Set in the gitignored terraform.tfvars."
  type        = string
}

variable "environment" {
  description = "GO_ENV value for the API container. Must stay \"production\": the server refuses fake billing and drops the test-login route only in production."
  type        = string
  default     = "production"
}

variable "alb_rule_priority" {
  description = "Priority for this product's ALB listener rule. Must be unique across products."
  type        = number
  default     = 310
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
  default     = "aitravel-api"
}

variable "api_image_tag" {
  description = "ECR image tag to deploy"
  type        = string
  default     = "latest"
}

variable "ecr_repository_name" {
  description = "ECR repository name for this product's API image (Terraform-managed; see ecr.tf)"
  type        = string
  default     = "aitravel-server"
}

# The shared t4g.large is CPU-bound, not memory-bound: 256 of 2048 units were
# free before this stack. 64 follows the meerkat/sjocamp Go-API precedent and
# leaves room for a rolling deploy (100/200) plus a migrator run. CPU units are
# scheduler shares, not caps, so the server still bursts on an idle host.
# See README.md "Capacity".
variable "api_container_cpu" {
  description = "CPU shares (weight) for the API container"
  type        = number
  default     = 64
}

variable "api_container_memory_reservation" {
  description = "Soft memory reservation (MB) — used for ECS scheduling"
  type        = number
  default     = 256
}

variable "api_container_memory" {
  description = "Hard memory cap (MB) — container killed if exceeded"
  type        = number
  default     = 512
}

variable "api_desired_count" {
  description = "Number of API tasks to run"
  type        = number
  default     = 1
}

# --- Migrator (one-shot Flyway task, run by CI with `ecs run-task`) ---

variable "migrator_ecr_repository_name" {
  description = "ECR repository name for the Flyway migrator image (Terraform-managed; see ecr.tf)"
  type        = string
  default     = "aitravel-migrator"
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

# --- Database pools ---
#
# The shared RDS is a db.t3.micro (~112 connections at the default
# max_connections formula). These cap aitravel's share of it.

variable "db_max_open_conns" {
  description = "DB_MAX_OPEN_CONNS for the API's request pool"
  type        = number
  default     = 10
}

variable "db_worker_max_open_conns" {
  description = "DB_WORKER_MAX_OPEN_CONNS for the Kafka-worker pool"
  type        = number
  default     = 5
}

# --- Media storage ---

variable "media_bucket_name" {
  description = "S3 bucket holding uploaded media (booking screenshots). Private — see media-storage.tf."
  type        = string
  default     = "protoapp-aitravel-media"
}
