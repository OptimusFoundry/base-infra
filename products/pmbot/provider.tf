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

data "aws_ssm_parameter" "cloudflare_api_key" {
  name = "/cloudflare/api_key"
}

provider "cloudflare" {
  api_key = data.aws_ssm_parameter.cloudflare_api_key.value
  email   = var.cloudflare_email
}
