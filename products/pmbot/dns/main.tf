# pmbot.protoapp.xyz -> the status page's CloudFront distribution (polymarket-bot CH-009).
#
# A separate root module on purpose. The Cloudflare provider needs the account's global API key (SSM
# /cloudflare/api_key); a provider in products/pmbot would make every CD plan read it, and the plan role runs PR
# workflows. pmbot-terraform.yml runs init/validate/plan in products/pmbot only, so CD never plans this directory
# (its fmt -check -recursive still formats it). The owner applies it by hand from a saved plan, once, after
# products/pmbot created the distribution (products/pmbot/README.md "Status page").
#
#   terraform -chdir=products/pmbot/dns init -input=false
#   TF_VAR_cloudflare_email=<owner's Cloudflare email> terraform -chdir=products/pmbot/dns plan -input=false -out=tfplan-dns
#   terraform -chdir=products/pmbot/dns apply tfplan-dns && rm products/pmbot/dns/tfplan-dns

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

  # Same bucket as products/pmbot, its own key. The CD roles' state grants cover state/* only.
  backend "s3" {
    bucket       = "pmbot-terraform-state"
    key          = "dns/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

variable "cloudflare_email" {
  description = "Cloudflare account email, paired with the global API key from SSM /cloudflare/api_key (TF_VAR_cloudflare_email; not committed)."
  type        = string
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Stack     = "product"
      Product   = "pmbot"
    }
  }
}

data "aws_ssm_parameter" "cloudflare_api_key" {
  name = "/cloudflare/api_key"
}

provider "cloudflare" {
  api_key = data.aws_ssm_parameter.cloudflare_api_key.value
  email   = var.cloudflare_email
}

data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = "protoapp-infra-terraform-state"
    key    = "state/terraform.tfstate"
    region = "us-east-1"
  }
}

data "terraform_remote_state" "pmbot" {
  backend = "s3"
  config = {
    bucket = "pmbot-terraform-state"
    key    = "state/terraform.tfstate"
    region = "us-east-1"
  }
}

resource "cloudflare_dns_record" "site" {
  zone_id = data.terraform_remote_state.platform.outputs.cloudflare_zone_id
  name    = data.terraform_remote_state.pmbot.outputs.site_domain
  type    = "CNAME"
  content = data.terraform_remote_state.pmbot.outputs.site_distribution_domain_name
  ttl     = 1
  proxied = false
}

output "site_record" {
  value       = "${cloudflare_dns_record.site.name} CNAME ${cloudflare_dns_record.site.content}"
  description = "The status page's DNS record"
}
