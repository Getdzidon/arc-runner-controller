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

# ── EKS cluster (control plane only — node group is created separately) ──────

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.15"

  name               = var.cluster_name
  kubernetes_version = "1.33"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access = true
  enable_irsa            = true

  create_node_security_group = true

  enable_cluster_creator_admin_permissions = true
}

# ── Wait for the control plane to stabilise before creating nodes ────────────
# Without this pause the node group can fail with "Unhealthy nodes" because
# the API server isn't fully ready to accept kubelet registrations yet.

resource "time_sleep" "wait_for_cluster" {
  depends_on      = [module.eks]
  create_duration = "120s"
}

# ── Managed node group ───────────────────────────────────────────────────────

resource "aws_eks_node_group" "default" {
  cluster_name    = module.eks.cluster_name
  node_group_name = "default"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = module.vpc.private_subnets
  instance_types  = [var.node_instance_type]

  scaling_config {
    min_size     = 1
    max_size     = 3
    desired_size = 2
  }

  depends_on = [
    time_sleep.wait_for_cluster,
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy,
  ]
}
