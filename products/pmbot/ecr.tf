# IMMUTABLE: CI pushes one tag per git SHA and a tag can never be overwritten, so a
# deploy (image_tag) and a rollback (the previous image_tag) are exact.
resource "aws_ecr_repository" "pmbot" {
  name                 = local.name
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  # Renaming or destroying the repository deletes every image in it.
  lifecycle {
    prevent_destroy = true
  }
}

# Keep the 30 newest images; older SHAs age out. A rollback further back than 30 pushes
# needs a rebuild.
resource "aws_ecr_lifecycle_policy" "pmbot" {
  repository = aws_ecr_repository.pmbot.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire all but the 30 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}

output "ecr_repository_url" {
  value       = aws_ecr_repository.pmbot.repository_url
  description = "ECR repository URL CI pushes to and the task definitions pull from"
}
