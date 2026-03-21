# ── Data sources ─────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}

data "tls_certificate" "eks_oidc" {
  url = module.eks.cluster_oidc_issuer_url
}

# ── EKS cluster ─────────────────────────────────────────────────────────────
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

  # EKS add-ons — vpc-cni and kube-proxy go Active without nodes
  addons = {
    "vpc-cni"    = { most_recent = true }
    "kube-proxy" = { most_recent = true }
  }

  # Disable the separate node security group — nodes will use the
  # EKS-managed cluster security group which already trusts itself.
  create_node_security_group = false

  enable_cluster_creator_admin_permissions = true

  access_entries = {
    # Allow the root account to view cluster resources in the AWS console
    root = {
      principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
    # Allow the local IAM user to run kubectl and manage the cluster
    admin_user = {
      principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${var.cluster_admin_username}"
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }
}


# ── Managed node group (separate so it waits for add-ons) ───────────────────

module "node_group" {
  source  = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  version = "~> 21.15"

  name               = "${var.cluster_name}-ng"
  cluster_name       = module.eks.cluster_name
  kubernetes_version = module.eks.cluster_version
  subnet_ids         = module.vpc.private_subnets

  cluster_primary_security_group_id = module.eks.cluster_primary_security_group_id
  cluster_service_cidr              = module.eks.cluster_service_cidr

  # No separate node SG — use the cluster's
  create_security_group = false

  instance_types = [var.node_instance_type]
  min_size       = 1
  max_size       = 3
  desired_size   = 2

  iam_role_additional_policies = {
    AmazonEKSWorkerNodePolicy          = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
    AmazonEC2ContainerRegistryReadOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
    AmazonEKS_CNI_Policy               = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  }

  depends_on = [module.eks]
}

# ── CoreDNS add-on (needs nodes, so it goes after the node group) ───────────

data "aws_eks_addon_version" "coredns" {
  addon_name         = "coredns"
  kubernetes_version = module.eks.cluster_version
  most_recent        = true
}

resource "aws_eks_addon" "coredns" {
  cluster_name  = module.eks.cluster_name
  addon_name    = "coredns"
  addon_version = data.aws_eks_addon_version.coredns.version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [module.node_group]
}

