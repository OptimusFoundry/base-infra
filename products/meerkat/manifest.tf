# See products/sjocamp/manifest.tf for the pattern + rationale.

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
      ecrRepository              = data.aws_ecr_repository.api.name
      ecsCluster                 = data.terraform_remote_state.platform.outputs.ecs_cluster_name
      ecsService                 = aws_ecs_service.ecs_service.name
      webappS3Bucket             = module.product.webapp_bucket_id
      cloudfrontDistributionId   = module.product.cloudfront_distribution_id
      captureWorkerEcrRepository = aws_ecr_repository.capture_worker.name
      captureWorkerEcsService    = aws_ecs_service.capture_worker.name
      # Repository NAME (not URL), joined to the ECR login's registry in CI.
      migratorEcrRepository  = aws_ecr_repository.migrator.name
      migratorTaskDefinition = aws_ecs_task_definition.migrator.family
      logGroup               = aws_cloudwatch_log_group.ecs_log_group.name
    }
    ssm = {
      productPrefix  = "/${var.product}"
      platformPrefix = "/platform"
    }
  })
}
