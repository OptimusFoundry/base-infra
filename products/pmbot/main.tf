# pmbot — the polymarket-bot sports stack (OptimusFoundry/polymarket-bot). Paper trading only.
#
# Runs on the shared platform ECS cluster like every other product: five long-running services,
# two EventBridge-scheduled tasks and a parked status-page writer, plus a static status site at
# pmbot.protoapp.xyz. No ALB route — nothing here serves an API — so modules/product is not used.
# See README.md.

terraform {
  required_version = ">= 1.15.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket       = "pmbot-terraform-state"
    key          = "state/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}
