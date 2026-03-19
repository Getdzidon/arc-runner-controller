output "eks_cluster_name" {
  description = "EKS cluster name — set as EKS_CLUSTER_NAME GitHub Actions secret"
  value       = module.eks.cluster_name
}

output "aws_region" {
  description = "AWS region — set as AWS_REGION GitHub Actions secret"
  value       = var.aws_region
}
