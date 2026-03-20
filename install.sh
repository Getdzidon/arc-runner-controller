#!/usr/bin/env bash
# install.sh — Bootstrap GitHub Actions Runner Controller (ARC)
#
# Required environment variables:
#   GITHUB_APP_ID                — GitHub App ID
#   GITHUB_APP_INSTALLATION_ID   — Installation ID of the GitHub App
#   GITHUB_APP_PRIVATE_KEY_PATH  — Path to the .pem private key file
#
# Optional:
#   GITHUB_CONFIG_URL            — Org or repo URL (default: https://github.com/getdzidon)
#   KUBECONFIG                   — Path to kubeconfig (default: ~/.kube/config)

set -euo pipefail

# ── Load pinned chart version ─────────────────────────────────────────────────
# shellcheck source=versions.env
# amazonq-ignore-next-line
source "$(dirname "$0")/versions.env"

ARC_NAMESPACE="arc-system"
RUNNERS_NAMESPACE="arc-runners"
CONTROLLER_RELEASE="arc"
RUNNER_SET_RELEASE="arc-runner-set"

# ── Validate required env vars ────────────────────────────────────────────────
: "${GITHUB_APP_ID:?Set GITHUB_APP_ID}"
: "${GITHUB_APP_INSTALLATION_ID:?Set GITHUB_APP_INSTALLATION_ID}"
: "${GITHUB_APP_PRIVATE_KEY_PATH:?Set GITHUB_APP_PRIVATE_KEY_PATH}"
GITHUB_CONFIG_URL="${GITHUB_CONFIG_URL:-https://github.com/getdzidon}"

# ── Create namespaces ─────────────────────────────────────────────────────────
kubectl create namespace "$ARC_NAMESPACE"     --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$RUNNERS_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Label arc-system so NetworkPolicy namespaceSelector works
kubectl label namespace "$ARC_NAMESPACE" kubernetes.io/metadata.name="$ARC_NAMESPACE" --overwrite

# ── Apply RBAC ────────────────────────────────────────────────────────────────
kubectl apply -f arc-system/rbac.yaml

# ── Apply NetworkPolicies ─────────────────────────────────────────────────────
kubectl apply -f arc-system/network-policy.yaml

# ── Create GitHub App secret ──────────────────────────────────────────────────
kubectl create secret generic arc-github-app-secret \
  --namespace "$RUNNERS_NAMESPACE" \
  --from-literal=github_app_id="$GITHUB_APP_ID" \
  --from-literal=github_app_installation_id="$GITHUB_APP_INSTALLATION_ID" \
  --from-file=github_app_private_key="$GITHUB_APP_PRIVATE_KEY_PATH" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── Install ARC controller ────────────────────────────────────────────────────
helm upgrade --install "$CONTROLLER_RELEASE" \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --version "$ARC_CHART_VERSION" \
  --namespace "$ARC_NAMESPACE" \
  --create-namespace \
  --values arc-system/arc-controller-values.yaml \
  --wait

# ── Install runner scale set ──────────────────────────────────────────────────
helm upgrade --install "$RUNNER_SET_RELEASE" \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version "$ARC_CHART_VERSION" \
  --namespace "$RUNNERS_NAMESPACE" \
  --create-namespace \
  --values arc-system/arc-runner-scale-set-values.yaml \
  --set githubConfigUrl="$GITHUB_CONFIG_URL" \
  --wait

# ── Apply ServiceMonitors (requires Prometheus Operator) ──────────────────────
if kubectl api-resources | grep -q servicemonitors; then
  kubectl apply -f arc-system/service-monitor.yaml
  echo "   ServiceMonitors applied."
else
  echo "   ⚠️  Prometheus Operator not found — skipping ServiceMonitors."
fi

echo ""
echo "✅ ARC installed successfully."
echo "   Controller namespace : $ARC_NAMESPACE"
echo "   Runners namespace    : $RUNNERS_NAMESPACE"
echo "   Chart version        : $ARC_CHART_VERSION"
echo "   Use 'runs-on: arc-runner-set' in your workflows."
