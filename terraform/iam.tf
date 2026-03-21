# ── IAM role for ESO (IRSA) ──────────────────────────────────────────────────
# Allows the External Secrets Operator service account to read
# secrets from AWS Secrets Manager via IRSA (IAM Roles for Service Accounts).

locals {
  oidc_issuer = trimprefix(module.eks.cluster_oidc_issuer_url, "https://")
}

resource "aws_iam_policy" "eso" {
  name = "ESO-ARC-SecretsPolicy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      Resource = "${aws_secretsmanager_secret.github_app.arn}*"
    }]
  })
}

resource "aws_iam_role" "eso" {
  name = "ESO-ARC-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.eks.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:sub" = "system:serviceaccount:arc-runners:external-secrets"
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eso" {
  role       = aws_iam_role.eso.name
  policy_arn = aws_iam_policy.eso.arn
}
