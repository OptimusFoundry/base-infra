# See products/sjocamp/manifest.tf for the pattern + rationale. The app repo
# reads /orca/manifest at deploy time instead of hardcoding any AWS identifier.

resource "aws_ssm_parameter" "manifest" {
  name = "/${var.product}/manifest"
  type = "String"
  tier = "Advanced"
  value = jsonencode({
    name = var.display_name
    slug = var.product
    domains = {
      app     = var.domain_name
      landing = var.landing_domain
    }
    aws = {
      region                     = var.aws_region
      ecrRepository              = aws_ecr_repository.api.name
      ecsCluster                 = data.terraform_remote_state.platform.outputs.ecs_cluster_name
      ecsService                 = aws_ecs_service.api.name
      webappS3Bucket             = module.product.webapp_bucket_id
      cloudfrontDistributionId   = module.product.cloudfront_distribution_id
      renderServiceEcrRepository = aws_ecr_repository.render_service.name
      renderServiceEcsService    = aws_ecs_service.render_service.name
      mediaS3Bucket              = aws_s3_bucket.media.id
      # Repository NAME (not URL), joined to the ECR login's registry in CI.
      migratorEcrRepository  = aws_ecr_repository.migrator.name
      migratorTaskDefinition = aws_ecs_task_definition.migrator.family
      logGroup               = aws_cloudwatch_log_group.api.name
    }
    ssm = {
      productPrefix  = "/${var.product}"
      platformPrefix = "/platform"
    }
  })
}
