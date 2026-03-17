# GitHub Actions Runner Controller (ARC)

Self-hosted ephemeral runners on Kubernetes using the official [ARC](https://github.com/actions/actions-runner-controller) Helm charts.

GitHub account: **getdzidon** — `https://github.com/getdzidon`

---

## Project structure

```
arc-runner-controller/
├── .github/
│   └── workflows/
│       ├── deploy-arc.yaml          # GitOps pipeline — deploys ARC itself
│       └── example-arc-job.yaml     # CI pipeline that runs ON ARC runners
├── arc-system/
│   ├── arc-controller-values.yaml   # Helm values for the ARC controller
│   ├── arc-runner-scale-set-values.yaml  # Helm values + autoscaling config
│   ├── rbac.yaml                    # ServiceAccount, Role, RoleBinding
│   ├── network-policy.yaml          # NetworkPolicies for runner isolation
│   ├── service-monitor.yaml         # Prometheus ServiceMonitors
│   ├── secret-store.yaml            # ESO SecretStore (Option C)
│   ├── external-secret.yaml         # ESO ExternalSecret (Option C)
│   └── github-app-secret.yaml.tpl   # Secret template (never commit real values)
├── versions.env                     # Pinned chart versions (managed by Renovate)
├── renovate.json                    # Automated dependency update config
├── install.sh                       # Local bootstrap script
├── .gitignore                       # Blocks .pem keys and plain secret files from Git
└── README.md
```

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| kubectl | ≥ 1.26 | [docs](https://kubernetes.io/docs/tasks/tools/) |
| helm | ≥ 3.12 | [docs](https://helm.sh/docs/intro/install/) |
| Kubernetes cluster | ≥ 1.26 | e.g. EKS, GKE, AKS, kind |
| aws cli | ≥ 2.x | [docs](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) — only needed for Option C |

Confirm your cluster connection before starting:

```bash
kubectl cluster-info
kubectl get nodes
```

---

## 1 — Create a GitHub App

### 1.1 Create the App

1. Go to **GitHub → Settings → Developer settings → GitHub Apps → New GitHub App**
2. Fill in:
   - **Name**: `arc-runner-getdzidon`
   - **Homepage URL**: `https://github.com/getdzidon`
   - **Webhook**: uncheck *Active*
3. Set **Repository permissions**:
   - `Actions` → Read & Write
   - `Administration` → Read & Write
   - `Checks` → Read & Write
   - `Metadata` → Read-only
4. Under **Where can this GitHub App be installed?** select *Only on this account*
5. Click **Create GitHub App**
6. On the next page, note the **App ID** (shown at the top)

### 1.2 Generate a private key

1. Scroll down to **Private keys** → click **Generate a private key**
2. A `.pem` file downloads automatically — keep it safe, you cannot re-download it

### 1.3 Install the App and get the Installation ID

1. In the left sidebar click **Install App** → click **Install** next to your account
2. Choose *All repositories* or select specific repos → click **Install**
3. After install you are redirected to:
   `https://github.com/settings/installations/<INSTALLATION_ID>`
4. Note the number at the end — that is your **Installation ID**

---

## 2 — Storing Kubernetes Secrets

ARC reads GitHub App credentials from a Kubernetes secret named `arc-github-app-secret` in the `arc-runners` namespace.

First, create the namespace (required for all options):

```bash
kubectl create namespace arc-runners
```

Choose one option:

---

### Option A — kubectl (quick, local dev)

```bash
kubectl create secret generic arc-github-app-secret \
  --namespace arc-runners \
  --from-literal=github_app_id=<APP_ID> \
  --from-literal=github_app_installation_id=<INSTALLATION_ID> \
  --from-file=github_app_private_key=/path/to/private-key.pem
```

Verify:

```bash
kubectl get secret arc-github-app-secret -n arc-runners
kubectl describe secret arc-github-app-secret -n arc-runners
```

> Skip to [Section 3](#3--install-arc) — `install.sh` will not re-create the secret if it already exists.

---

### Option B — Sealed Secrets (GitOps-safe, recommended for teams)

Sealed Secrets encrypts the secret so it is safe to commit to Git.

**Install the controller:**

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace kube-system --wait
```

**Install the kubeseal CLI:**

```bash
# macOS
brew install kubeseal

# Linux
KUBESEAL_VERSION=0.26.0
wget "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
tar -xvzf kubeseal-*.tar.gz kubeseal
sudo mv kubeseal /usr/local/bin/
```

**Seal and apply the secret:**

```bash
# 1. Generate a plain secret manifest — DO NOT commit this file
kubectl create secret generic arc-github-app-secret \
  --namespace arc-runners \
  --from-literal=github_app_id=<APP_ID> \
  --from-literal=github_app_installation_id=<INSTALLATION_ID> \
  --from-file=github_app_private_key=/path/to/private-key.pem \
  --dry-run=client -o yaml > /tmp/arc-secret.yaml

# 2. Encrypt into a SealedSecret — this file IS safe to commit
kubeseal --format yaml < /tmp/arc-secret.yaml > arc-system/arc-github-app-sealed-secret.yaml

# 3. Apply it
kubectl apply -f arc-system/arc-github-app-sealed-secret.yaml

# 4. Remove the plain secret immediately
rm /tmp/arc-secret.yaml

# 5. Verify the controller decrypted it into a real secret
kubectl get secret arc-github-app-secret -n arc-runners
```

---

### Option C — External Secrets Operator + AWS Secrets Manager (production)

Secrets live in AWS Secrets Manager; ESO syncs them into Kubernetes automatically.

**Step 1 — Store the secret in AWS:**

```bash
PEM_CONTENT=$(awk 'NF {sub(/\r/, ""); printf "%s\\n",$0;}' /path/to/private-key.pem)

aws secretsmanager create-secret \
  --name arc/github-app \
  --region eu-central-1 \
  --secret-string "{
    \"github_app_id\": \"<APP_ID>\",
    \"github_app_installation_id\": \"<INSTALLATION_ID>\",
    \"github_app_private_key\": \"${PEM_CONTENT}\"
  }"
```

**Step 2 — Create an IAM role for ESO (IRSA):**

```bash
# Get your cluster OIDC issuer
aws eks describe-cluster --name <CLUSTER_NAME> --region <REGION> \
  --query "cluster.identity.oidc.issuer" --output text

# Create IAM policy
cat > /tmp/eso-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
    "Resource": "arn:aws:secretsmanager:eu-central-1:<ACCOUNT_ID>:secret:arc/github-app*"
  }]
}
EOF

aws iam create-policy \
  --policy-name ESO-ARC-SecretsPolicy \
  --policy-document file:///tmp/eso-policy.json

# Create IAM role with OIDC trust
cat > /tmp/eso-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/<CLUSTER_OIDC>" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "<CLUSTER_OIDC>:sub": "system:serviceaccount:external-secrets:external-secrets-sa",
        "<CLUSTER_OIDC>:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF

aws iam create-role --role-name ESO-ARC-Role \
  --assume-role-policy-document file:///tmp/eso-trust.json

aws iam attach-role-policy --role-name ESO-ARC-Role \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/ESO-ARC-SecretsPolicy
```

**Step 3 — Install ESO:**

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::<ACCOUNT_ID>:role/ESO-ARC-Role \
  --wait
```

**Step 4 — Apply the SecretStore and ExternalSecret:**

```bash
kubectl apply -f arc-system/secret-store.yaml
kubectl apply -f arc-system/external-secret.yaml

# Verify sync — STATUS should show SecretSynced
kubectl get externalsecret arc-github-app-secret -n arc-runners
kubectl get secret arc-github-app-secret -n arc-runners
```

If STATUS shows `SecretSyncedError`:

```bash
kubectl describe externalsecret arc-github-app-secret -n arc-runners
```

---

## 3 — RBAC

Runner pods use a dedicated least-privilege ServiceAccount (`arc-runner-sa`) defined in `arc-system/rbac.yaml`. The Role grants only what ARC needs to manage ephemeral job pods:

| Resource | Verbs |
|----------|-------|
| pods | get, list, watch, create, delete |
| pods/log | get, list, watch |
| secrets | get, list |
| jobs (batch) | get, list, watch, create, delete |

`install.sh` and the `deploy-arc.yaml` workflow both apply this before installing Helm charts.

---

## 4 — Network isolation

`arc-system/network-policy.yaml` applies four policies to the `arc-runners` namespace:

| Policy | Effect |
|--------|--------|
| `arc-runners-deny-ingress` | Blocks all inbound traffic to runner pods by default |
| `arc-runners-allow-dns` | Allows UDP/TCP port 53 for DNS resolution |
| `arc-runners-allow-egress-https` | Allows outbound HTTPS (443) only — for GitHub API and registries |
| `arc-runners-allow-controller` | Allows inbound traffic from `arc-system` namespace only |

The `arc-system` namespace is labelled `kubernetes.io/metadata.name=arc-system` by `install.sh` so the namespaceSelector works correctly.

---

## 5 — Install ARC

```bash
export GITHUB_APP_ID=<app-id>
export GITHUB_APP_INSTALLATION_ID=<installation-id>
export GITHUB_APP_PRIVATE_KEY_PATH=/path/to/private-key.pem
# GITHUB_CONFIG_URL defaults to https://github.com/getdzidon

chmod +x install.sh
./install.sh
```

The script will, in order:
1. Source `versions.env` for the pinned chart version
2. Create `arc-system` and `arc-runners` namespaces
3. Label `arc-system` for NetworkPolicy selectors
4. Apply RBAC (`rbac.yaml`)
5. Apply NetworkPolicies (`network-policy.yaml`)
6. Create the GitHub App secret
7. Install the ARC controller via Helm
8. Install the runner scale set via Helm
9. Apply ServiceMonitors if Prometheus Operator is present

---

## 6 — GitOps deploy pipeline

`.github/workflows/deploy-arc.yaml` automatically redeploys ARC when any of these change:

- `arc-system/**` — any manifest or values file
- `versions.env` — chart version bump (triggered by Renovate)
- `install.sh`

The pipeline runs on `ubuntu-latest` (GitHub-hosted) for the initial bootstrap, then subsequent runs can be switched to `arc-runner-set` once ARC is up.

**Required GitHub Actions secrets:**

| Secret | Description |
|--------|-------------|
| `AWS_IAM_ROLE_ARN` | ARN of the IAM role GitHub Actions will assume via OIDC e.g. `arn:aws:iam::<ACCOUNT_ID>:role/github-actions-arc-role` |
| `AWS_REGION` | e.g. `eu-central-1` |
| `EKS_CLUSTER_NAME` | Your EKS cluster name |

> **Note:** `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are no longer needed and should be deleted from your GitHub secrets.

**Setting up the IAM role for OIDC:**

Before the pipeline can run, create an IAM role that trusts GitHub's OIDC provider:

```bash
# 1. Add GitHub OIDC provider to AWS (one time per account)
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com

# 2. Create trust policy
cat > /tmp/github-oidc-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:getdzidon/arc-runner-controller:*"
      }
    }
  }]
}
EOF

# 3. Create the role
aws iam create-role \
  --role-name github-actions-arc-role \
  --assume-role-policy-document file:///tmp/github-oidc-trust.json

# 4. Attach required permissions (EKS access)
aws iam attach-role-policy \
  --role-name github-actions-arc-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
```

---

## 7 — Secret template (github-app-secret.yaml.tpl)

`arc-system/github-app-secret.yaml.tpl` is a reference template showing the exact shape of the `arc-github-app-secret` Kubernetes secret that ARC expects. It contains placeholder values only and is never applied directly.

Use it to:
- Understand which fields `install.sh` and the three secret options in Section 2 are creating
- Manually construct the secret in environments where neither `kubectl` nor ESO is available

Never populate this file with real values and commit it — use one of the three options in Section 2 instead.

---

## 8 — .gitignore

`.gitignore` prevents sensitive files from being accidentally committed:

| Pattern | What it blocks |
|---------|----------------|
| `*.pem` | GitHub App private key files |
| `*.key` | Any raw key files |
| `.env` | Local environment variable files |
| `arc-system/github-app-secret.yaml` | Plain (unencrypted) secret manifests |

---

## 9 — Automated version updates (Renovate)

`renovate.json` configures Renovate Bot to watch `versions.env` and open a PR when a new ARC chart version is released. PRs are labelled `dependencies` and `helm` and require manual approval before merge.

To enable: install the [Renovate GitHub App](https://github.com/apps/renovate) on your repository.

---

## 10 — Observability

`arc-system/service-monitor.yaml` defines two Prometheus ServiceMonitors:

| Monitor | Namespace | What it scrapes |
|---------|-----------|-----------------|
| `arc-controller-metrics` | arc-system | ARC controller `/metrics` every 30s |
| `arc-runner-set-metrics` | arc-runners | Runner scale set listener `/metrics` every 30s |

Requires [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) or standalone Prometheus Operator. The `release: prometheus` label must match your Prometheus Operator's `serviceMonitorSelector`.

---

## 11 — Use in workflows

```yaml
jobs:
  build:
    runs-on: arc-runner-set   # matches runnerScaleSetName in arc-runner-scale-set-values.yaml
    steps:
      - uses: actions/checkout@v4
      - run: echo "Running on ARC for getdzidon!"
```

---

## Autoscaling behaviour

| Setting | Value | Description |
|---------|-------|-------------|
| `minRunners` | 1 | Always-warm runner pod |
| `maxRunners` | 10 | Hard cap; increase for burst workloads |
| Scale trigger | Queued jobs | ARC scales up when jobs are waiting |
| Runner lifecycle | Ephemeral | Pod is destroyed after each job |

To change limits, edit `arc-system/arc-runner-scale-set-values.yaml` and push to `main` — the deploy pipeline will apply the change automatically.

---

## Storage class by cloud provider

Edit `storageClassName` in `arc-system/arc-runner-scale-set-values.yaml`:

| Provider | storageClassName |
|----------|-----------------|
| EKS | `gp2` or `gp3` |
| GKE | `standard` |
| AKS | `default` |
| kind / local | `standard` |

---

## Verify installation

```bash
kubectl get pods -n arc-system                        # controller
kubectl get autoscalingrunnerset -n arc-runners       # scale set
kubectl get pods -n arc-runners                       # runner pods (appear when jobs queue)
kubectl get servicemonitor -n arc-system              # Prometheus monitors
kubectl get networkpolicy -n arc-runners              # network policies
kubectl get rolebinding -n arc-runners                # RBAC
```

---

## Troubleshooting

**Controller pod is CrashLoopBackOff**
```bash
kubectl logs -n arc-system -l app.kubernetes.io/name=gha-runner-scale-set-controller
```
Most common cause: `arc-github-app-secret` is missing or in the wrong namespace.

**Runners not picking up jobs**
```bash
kubectl logs -n arc-runners -l app.kubernetes.io/name=arc-runner-set
```
Check that `githubConfigUrl` matches the exact org/repo URL and the GitHub App is installed there.

**Secret not found**
```bash
kubectl get secret arc-github-app-secret -n arc-runners
```
The secret must be in `arc-runners`, not `arc-system`.

**NetworkPolicy blocking runner traffic**
```bash
kubectl describe networkpolicy -n arc-runners
```
Ensure the `arc-system` namespace has the label `kubernetes.io/metadata.name=arc-system` (applied by `install.sh`).

**Helm OCI pull fails**
```bash
helm registry login ghcr.io -u <github-username> --password-stdin <<< <github-pat>
```
Requires a GitHub PAT with `read:packages` scope.

**ServiceMonitor not scraping**
```bash
kubectl get servicemonitor -n arc-system -o yaml
```
Ensure the `release: prometheus` label matches your Prometheus Operator's `serviceMonitorSelector` value.

---

## Uninstall

```bash
helm uninstall arc-runner-set -n arc-runners
helm uninstall arc -n arc-system
kubectl delete -f arc-system/rbac.yaml
kubectl delete -f arc-system/network-policy.yaml
kubectl delete -f arc-system/service-monitor.yaml
kubectl delete namespace arc-runners arc-system
```
