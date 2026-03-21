variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-central-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "node_instance_type" {
  description = "EC2 instance type for EKS worker nodes"
  type        = string
  default     = "t3.medium"
}

variable "github_app_id" {
  description = "GitHub App ID (from Step 1)"
  type        = string
  sensitive   = true
}

variable "github_app_installation_id" {
  description = "GitHub App Installation ID (from Step 1)"
  type        = string
  sensitive   = true
}

variable "github_app_private_key" {
  description = "GitHub App private key PEM content (from Step 1)"
  type        = string
  sensitive   = true
}

variable "cluster_admin_username" {
  description = "IAM username to grant EKS cluster admin access"
  type        = string
}
