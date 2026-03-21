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

resource "kubectl_manifest" "arc_runners_namespace" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Namespace
    metadata:
      name: arc-runners
  YAML

  depends_on = [time_sleep.wait_for_eso_crds]
}

resource "kubectl_manifest" "eso_service_account" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: external-secrets
      namespace: arc-runners
      annotations:
        eks.amazonaws.com/role-arn: ${aws_iam_role.eso.arn}
  YAML

  depends_on = [kubectl_manifest.arc_runners_namespace]
}

resource "kubectl_manifest" "secret_store" {
  yaml_body = templatefile("${path.module}/../arc-system/secret-store.yaml", {})

  depends_on = [kubectl_manifest.eso_service_account]
}

resource "kubectl_manifest" "external_secret" {
  yaml_body = templatefile("${path.module}/../arc-system/external-secret.yaml", {})

  depends_on = [kubectl_manifest.secret_store]
}
