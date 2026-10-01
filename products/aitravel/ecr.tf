resource "aws_ecr_repository" "api" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Flyway image carrying base-server/migrations; CI pushes it before running the
# migrator task (migrator.tf).
resource "aws_ecr_repository" "migrator" {
  name                 = var.migrator_ecr_repository_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# CI pushes on every merge to main; without expiry both repos grow unbounded.
# Keep the last 10 images in each and let the rest age out.
locals {
  ecr_keep_last_10 = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire all but the 10 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name
  policy     = local.ecr_keep_last_10
}

resource "aws_ecr_lifecycle_policy" "migrator" {
  repository = aws_ecr_repository.migrator.name
  policy     = local.ecr_keep_last_10
}
