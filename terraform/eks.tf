# ── Data sources ─────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}

data "aws_eks_cluster" "this" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]
}

data "aws_eks_cluster_auth" "this" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]
}

data "tls_certificate" "eks_oidc" {
  url = module.eks.cluster_oidc_issuer_url
}

# ── EKS cluster + managed node group ────────────────────────────────────────
# Nodes use the EKS-managed cluster security group directly (no separate node
# SG). This ensures bidirectional communication between the control plane and
# nodes without needing cross-SG rules.

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.15"

  name               = var.cluster_name
  kubernetes_version = "1.35"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access  = true
  endpoint_private_access = true
  enable_irsa            = true

  # EKS add-ons — required for nodes to become Ready
  cluster_addons = {
    "vpc-cni"    = { most_recent = true }
    "kube-proxy" = { most_recent = true }
    "coredns"    = { most_recent = true }
  }

  # Disable the separate node security group — nodes will use the
  # EKS-managed cluster security group which already trusts itself.
  create_node_security_group = false

  eks_managed_node_groups = {
    default = {
      instance_types = [var.node_instance_type]

      min_size     = 1
      max_size     = 3
      desired_size = 2

      iam_role_additional_policies = {
        AmazonEKSWorkerNodePolicy          = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
        AmazonEC2ContainerRegistryReadOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
        AmazonEKS_CNI_Policy               = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
      }
    }
  }

  enable_cluster_creator_admin_permissions = true
}
