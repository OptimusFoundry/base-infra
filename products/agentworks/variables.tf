variable "product" {
  description = "Product slug — used in resource names, SSM paths and the X-Product-Id routing header"
  type        = string
  default     = "agentworks"
}

variable "domain_name" {
  description = "Domain served by this product"
  type        = string
  default     = "agentworks.protoapp.xyz"
}

variable "aws_region" {
  description = "AWS region (must match platform)"
  type        = string
  default     = "us-east-1"
}

variable "display_name" {
  description = "Human-facing product name (used in the SSM manifest the app repo reads)"
  type        = string
  default     = "agentworks"
}

variable "landing_domain" {
  description = "Domain serving the marketing landing page. agentworks has no separate landing on AWS — same as app."
  type        = string
  default     = "agentworks.protoapp.xyz"
}

variable "cloudflare_email" {
  description = "Cloudflare account email, paired with the global API key from SSM /cloudflare/api_key. Set in the gitignored terraform.tfvars."
  type        = string
}

variable "environment" {
  description = "GO_ENV value for the API container. Must stay \"production\": it is what makes the server require GATEWAY_TOKEN_KEY and a KMS key instead of a local SECRETS_KEY."
  type        = string
  default     = "production"
}

variable "alb_rule_priority" {
  description = "Priority for this product's ALB listener rule. Must be unique across products."
  type        = number
  default     = 320
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
  default     = "agentworks-api"
}

variable "api_image_tag" {
  description = "ECR image tag to deploy"
  type        = string
  default     = "latest"
}

variable "ecr_repository_name" {
  description = "ECR repository name for this product's API image (Terraform-managed; see ecr.tf)"
  type        = string
  default     = "agentworks-server"
}

# 64 follows the aitravel/meerkat/sjocamp Go-API precedent. The host was moved
# to a t4g.2xlarge; on 2026-10-09 it had ~4.3k CPU units and ~21 GiB free.
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
  default     = "agentworks-migrator"
}

variable "migrator_image_tag" {
  description = "ECR image tag for the migrator task"
  type        = string
  default     = "latest"
}

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

# --- Kafka ---

# The broker is shared and single-node; the server's default of 12 partitions
# for each of its three agentworks.* topics is sized for a dedicated host.
variable "kafka_partitions" {
  description = "KAFKA_PARTITIONS for the agentworks.inbound/platform/transcript topics"
  type        = number
  default     = 3
}

# --- Media storage ---

variable "media_bucket_name" {
  description = "S3 bucket holding attachments and transcripts. Private — see media-storage.tf."
  type        = string
  default     = "protoapp-agentworks-media"
}
