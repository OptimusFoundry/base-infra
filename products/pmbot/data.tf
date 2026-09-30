data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = "protoapp-infra-terraform-state"
    key    = "state/terraform.tfstate"
    region = var.aws_region
  }
}

data "aws_caller_identity" "current" {}

# ECS-optimized Amazon Linux 2023 arm64 image id, published by AWS (the same parameter
# platform/ecs.tf:72 resolves). Resolving it here guarantees an arm64 AMI for the t4g host.
data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/arm64/recommended/image_id"
}

locals {
  # Every resource name derives from this. It is fixed on purpose: a rename forces
  # replacement of the ECR repository (and its images), log groups and roles.
  name = "pmbot"

  # Platform outputs (platform/outputs.tf). Read-only: nothing here writes to platform.
  alerts_topic_arn  = data.terraform_remote_state.platform.outputs.alerts_topic_arn
  vpc_id            = data.terraform_remote_state.platform.outputs.vpc_id
  public_subnet_ids = data.terraform_remote_state.platform.outputs.public_subnet_ids

  # pmbot owns its cluster (owner decision D1 = b); the shared ecs-cluster is never read.
  cluster_arn  = aws_ecs_cluster.pmbot.arn
  cluster_name = aws_ecs_cluster.pmbot.name

  # pmbot tasks stay pinned to the pmbot instance by a custom ECS instance attribute; with
  # a dedicated cluster this is belt and braces.
  placement_attribute  = "pmbot"
  placement_value      = "dedicated"
  placement_expression = "attribute:${local.placement_attribute} == ${local.placement_value}"
}
