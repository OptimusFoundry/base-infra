# pmbot: dedicated ECS capacity, ECR, roles, services, schedule and alarms for the
# polymarket-bot sports stack. It reads `platform` through terraform_remote_state and
# changes nothing in it. Applied by the owner from a saved plan, never by an agent.

terraform {
  required_version = ">= 1.15.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Created by hand before `terraform init` (README, owner action 1).
  backend "s3" {
    bucket = "pmbot-terraform-state"
    key    = "state/terraform.tfstate"
    region = "us-east-1"
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
