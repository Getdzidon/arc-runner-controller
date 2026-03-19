output "eks_cluster_name" {
  description = "EKS cluster name — set as EKS_CLUSTER_NAME GitHub Actions secret"
  value       = module.eks.cluster_name
}

output "github_actions_role_arn" {
  description = "IAM role ARN for GitHub Actions OIDC — set as AWS_IAM_ROLE_ARN GitHub Actions secret"
  value       = aws_iam_role.github_actions.arn
}

output "aws_region" {
  description = "AWS region — set as AWS_REGION GitHub Actions secret"
  value       = var.aws_region
}
