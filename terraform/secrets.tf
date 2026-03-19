resource "aws_secretsmanager_secret" "github_app" {
  name                    = "arc/github-app-secret"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "github_app" {
  secret_id = aws_secretsmanager_secret.github_app.id
  secret_string = jsonencode({
    github_app_id              = var.github_app_id
    github_app_installation_id = var.github_app_installation_id
    github_app_private_key     = var.github_app_private_key
  })
}
