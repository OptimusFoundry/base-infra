# pmbot: dedicated ECS capacity, ECR, roles, services, schedule and alarms for the
# polymarket-bot sports stack. It reads `platform` through terraform_remote_state and
# changes nothing in it. Applied by base-infra CI (.github/workflows/pmbot-terraform.yml, CH-008) after
# ci/plan_guard.py, or by the owner from a saved plan; never by an agent.

terraform {
  required_version = ">= 1.15.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Created by hand before `terraform init` (README, owner action 1).
  # S3 native locking (state/terraform.tfstate.tflock): CI applies and a local apply exclude each other.
  backend "s3" {
    bucket       = "pmbot-terraform-state"
    key          = "state/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Stack     = "product"
      Product   = var.product
    }
  }
}
