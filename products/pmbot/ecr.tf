# IMMUTABLE: CI pushes one tag per git SHA and target, so a deploy and a rollback are exact.
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

# Every push is four images (collect, model, trade, research), so 120 is about 30 pushes of
# rollback window. A rollback further back needs a rebuild.
resource "aws_ecr_lifecycle_policy" "pmbot" {
  repository = aws_ecr_repository.pmbot.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire all but the 120 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 120
      }
      action = { type = "expire" }
    }]
  })
}
