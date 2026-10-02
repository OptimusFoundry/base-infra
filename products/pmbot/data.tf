data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = "protoapp-infra-terraform-state"
    key    = "state/terraform.tfstate"
    region = var.aws_region
  }
}

data "aws_caller_identity" "current" {}

locals {
  # Every resource name derives from this. Fixed on purpose: a rename replaces the ECR
  # repository (and its images), the log groups and the roles.
  name       = "pmbot"
  account_id = data.aws_caller_identity.current.account_id

  cluster_id       = data.terraform_remote_state.platform.outputs.ecs_cluster_id
  cluster_name     = data.terraform_remote_state.platform.outputs.ecs_cluster_name
  alerts_topic_arn = data.terraform_remote_state.platform.outputs.alerts_topic_arn
}
