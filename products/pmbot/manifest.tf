# See products/sjocamp/manifest.tf for the pattern. Deploy tooling reads /pmbot/manifest instead of
# hardcoding AWS identifiers.

resource "aws_ssm_parameter" "manifest" {
  name = "/${var.product}/manifest"
  type = "String"
  tier = "Advanced"
  value = jsonencode({
    name = "pmbot"
    slug = var.product
    domains = {
      app = local.site_domain
    }
    aws = {
      region                   = var.aws_region
      ecrRepository            = aws_ecr_repository.pmbot.name
      ecsCluster               = local.cluster_name
      ecsServices              = merge({ for key, service in aws_ecs_service.svc : key => service.name }, { status = aws_ecs_service.status.name })
      schedules                = { "daily-ingest" = aws_scheduler_schedule.daily_ingest.name, predictor = aws_scheduler_schedule.predictor.name }
      siteS3Bucket             = aws_s3_bucket.site.id
      cloudfrontDistributionId = aws_cloudfront_distribution.site.id
      dataS3Bucket             = var.data_bucket
    }
    ssm = {
      productPrefix  = "/${var.product}"
      platformPrefix = "/platform"
    }
  })
}
