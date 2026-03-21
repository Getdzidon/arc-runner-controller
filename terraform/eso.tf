resource "helm_release" "eso" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  wait             = true

  set = [
    {
      name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = aws_iam_role.eso.arn
    }
  ]

  # Wait for nodes to be healthy before installing
  depends_on = [module.node_group]
}

resource "time_sleep" "wait_for_eso_crds" {
  create_duration = "30s"
  depends_on      = [helm_release.eso]
}

resource "kubectl_manifest" "secret_store" {
  yaml_body = templatefile("${path.module}/../arc-system/secret-store.yaml", {})

  depends_on = [time_sleep.wait_for_eso_crds]
}

resource "kubectl_manifest" "external_secret" {
  yaml_body = templatefile("${path.module}/../arc-system/external-secret.yaml", {})

  depends_on = [kubectl_manifest.secret_store]
}
