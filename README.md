# GitHub Actions Runner Controller (ARC)

Self-hosted ephemeral runners on Kubernetes using the official [ARC](https://github.com/actions/actions-runner-controller) Helm charts.

GitHub account: **getdzidon** — `https://github.com/getdzidon`

---

## How it works

```
Manual steps (one-time)  →  push to main  →  deploy-arc.yaml runs  →  ARC is live
```

Once the manual steps below are done and the code is pushed to `main`, the `deploy-arc.yaml` pipeline fully deploys ARC automatically — no further intervention needed.

---

## Project structure

```
arc-runner-controller/
├── .github/
│   ├── workflows/
│   │   ├── deploy-terraform.yaml         # Pipeline — provisions AWS infra + EKS via Terraform (Option D)
│   │   ├── deploy-arc.yaml               # Pipeline — deploys ARC onto the cluster (automated)
│   │   └── example-arc-job.yaml          # CI pipeline that runs ON ARC runners
│   └── dependabot.yml
├── arc-system/
│   ├── arc-controller-values.yaml        # Helm values for the ARC controller
│   ├── arc-runner-scale-set-values.yaml  # Helm values + autoscaling config
│   ├── rbac.yaml                         # ServiceAccount, Role, RoleBinding
│   ├── network-policy.yaml               # NetworkPolicies for runner isolation
│   ├── service-monitor.yaml              # Prometheus ServiceMonitors
│   ├── secret-store.yaml                 # ESO SecretStore (Options C and D)
│   ├── external-secret.yaml              # ESO ExternalSecret (Options C and D)
│   └── github-app-secret.yaml.tpl        # Secret shape reference — never commit real values
├── terraform/
│   ├── providers.tf                      # Terraform block, backend, provider configs
│   ├── vpc.tf                            # VPC module
│   ├── eks.tf                            # EKS module + data sources
│   ├── iam.tf                            # ESO IRSA role + policy
│   ├── secrets.tf                        # AWS Secrets Manager
│   ├── eso.tf                            # ESO Helm release + SecretStore + ExternalSecret
│   ├── variables.tf                      # Input variables
│   ├── outputs.tf                        # Outputs: cluster name, role ARN, region
│   └── terraform.tfvars                  # Your values — blocked by .gitignore, never commit
├── versions.env                          # Pinned chart versions (updated by Renovate)
├── renovate.json                         # Automated dependency update config
├── install.sh                            # Local bootstrap script (alternative to the pipeline)
├── .gitignore
└── README.md
```

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| kubectl | ≥ 1.26 | [docs](https://kubernetes.io/docs/tasks/tools/) |
| helm | ≥ 3.12 | [docs](https://helm.sh/docs/intro/install/) |
| Kubernetes cluster | ≥ 1.26 | e.g. EKS, GKE, AKS, kind — **see note below** |
| aws cli | ≥ 2.x | [docs](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| terraform | ≥ 1.6 | [docs](https://developer.hashicorp.com/terraform/install) — only needed for Option D |

> **Kubernetes cluster:** ARC requires a running Kubernetes cluster. If you do not have one, use **Option D** in Step 3 — it provisions an EKS cluster via Terraform as part of the setup. If you already have a cluster (EKS, GKE, AKS, or kind), skip Option D and proceed with Options A, B, or C.

---

## ⚠️ Manual steps — do these first, in order

Complete all of them before pushing to `main`.

---

### 🔵 Step 1 — Create a GitHub App

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
6. Note the `App ID` shown at the top of the next page

**Generate a private key:**

1. Scroll down to **Private keys** → click **Generate a private key**
2. A `.pem` file downloads — keep it safe, you cannot re-download it

**Install the App and get the Installation ID:**

1. In the left sidebar click **Install App** → click **Install** next to your account
2. Choose *All repositories* or select specific repos → click **Install**
3. After install you are redirected to:
   `https://github.com/settings/installations/<INSTALLATION_ID>`
4. Note the number at the end — that is your `Installation ID`

You now have three values you will need in the steps below:
- `APP_ID`
- `INSTALLATION_ID`
- `/path/to/private-key.pem`

---

### 🟢 Step 2 — Create the GitHub Actions OIDC provider and IAM role

The deploy pipelines authenticate to AWS via OIDC — no static credentials. The OIDC provider must exist in your AWS account before anything else can run — both the `deploy-arc.yaml` pipeline and Terraform (Option D) depend on it.

> ⚠️ **Step 2 is required regardless of which option you choose in Step 3.** Options A, B, and C do not use OIDC directly, but the deploy pipelines (`deploy-arc.yaml` and `deploy-terraform.yaml`) authenticate to AWS via this OIDC role. Option D additionally requires the OIDC provider to exist because Terraform references it via a `data` source.

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

# 4. Attach EKS access
aws iam attach-role-policy \
  --role-name github-actions-arc-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
```

Note the role ARN — you need it in Step 4.

---

### 🟡 Step 3 — Create the Kubernetes secret

The deploy pipeline assumes `arc-github-app-secret` already exists in the `arc-runners` namespace. It does not create it. You must create it once before the first deploy.

Choose one option:

---

#### 🟡 Option A — kubectl (quick, local dev)

```bash
kubectl create namespace arc-runners

kubectl create secret generic arc-github-app-secret \
  --namespace arc-runners \
  --from-literal=github_app_id=<APP_ID> \
  --from-literal=github_app_installation_id=<INSTALLATION_ID> \
  --from-file=github_app_private_key=/path/to/private-key.pem
```

Verify:

```bash
kubectl get secret arc-github-app-secret -n arc-runners
```

---

#### 🟡 Option B — Sealed Secrets (GitOps-safe, recommended for teams)

Sealed Secrets encrypts the secret so it is safe to commit to Git.

**Install the controller:**

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace kube-system --wait
```

**Install the kubeseal CLI:**

```powershell
# Windows (winget)
winget install bitnami.kubeseal

# Windows (Chocolatey)
choco install kubeseal

# Windows (manual)
$VERSION = "0.26.0"
Invoke-WebRequest -Uri "https://github.com/bitnami-labs/sealed-secrets/releases/download/v$VERSION/kubeseal-$VERSION-windows-amd64.tar.gz" -OutFile kubeseal.tar.gz
tar -xzf kubeseal.tar.gz kubeseal.exe
Move-Item kubeseal.exe C:\Windows\System32\kubeseal.exe   # or any directory on your PATH
```

```bash
# macOS
brew install kubeseal

# Linux
KUBESEAL_VERSION=0.26.0
wget "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
tar -xvzf kubeseal-*.tar.gz kubeseal
sudo mv kubeseal /usr/local/bin/
```

**Seal and apply:**

```bash
kubectl create namespace arc-runners

# Generate plain secret — DO NOT commit this file
kubectl create secret generic arc-github-app-secret \
  --namespace arc-runners \
  --from-literal=github_app_id=<APP_ID> \
  --from-literal=github_app_installation_id=<INSTALLATION_ID> \
  --from-file=github_app_private_key=/path/to/private-key.pem \
  --dry-run=client -o yaml > /tmp/arc-secret.yaml

# Encrypt — this file IS safe to commit
kubeseal --format yaml < /tmp/arc-secret.yaml > arc-system/arc-github-app-sealed-secret.yaml

# Apply and clean up
kubectl apply -f arc-system/arc-github-app-sealed-secret.yaml
rm /tmp/arc-secret.yaml

# Verify the controller decrypted it
kubectl get secret arc-github-app-secret -n arc-runners
```

---

#### 🟡 Option C — External Secrets Operator + AWS Secrets Manager (production)

Secrets live in AWS Secrets Manager; ESO syncs them into Kubernetes automatically.

**Store the secret in AWS:**

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

**Create an IAM role for ESO (IRSA):**

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

**Install ESO:**

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::<ACCOUNT_ID>:role/ESO-ARC-Role \
  --wait
```

**Apply the SecretStore and ExternalSecret:**

```bash
kubectl apply -f arc-system/secret-store.yaml
kubectl apply -f arc-system/external-secret.yaml

# Verify — STATUS should show SecretSynced
kubectl get externalsecret arc-github-app-secret -n arc-runners
kubectl get secret arc-github-app-secret -n arc-runners
```

---

#### 🟡 Option D — Terraform (provisions everything: EKS cluster + IAM + secrets + ESO)

Use this option if you do not have an existing Kubernetes cluster, or if you want all AWS infrastructure managed as code. Requires Step 2 (OIDC provider) to be completed first.

Terraform will create:
- VPC with public and private subnets
- EKS cluster (Kubernetes 1.33, t3.medium nodes)
- EKS OIDC provider and IAM role for ESO (`ESO-ARC-Role`)
- AWS Secrets Manager secret (`arc/github-app`) with your GitHub App credentials
- External Secrets Operator installed via Helm
- `SecretStore` and `ExternalSecret` applied to the cluster

**Before running Terraform, update** the `backend "s3"` block in `terraform/providers.tf` with your S3 bucket name and region for remote state.

**Option 1 — Run Terraform locally:**

```bash
cd terraform

# Edit terraform.tfvars with your APP_ID, INSTALLATION_ID, and PEM content
terraform init
terraform plan
terraform apply
```

**Option 2 — Run via the pipeline:**

The `deploy-terraform.yaml` pipeline runs Terraform automatically when changes are pushed to `terraform/**`. Before pushing, set these GitHub Actions secrets:

| Secret | Value |
|--------|-------|
| `AWS_IAM_ROLE_ARN` | The OIDC role ARN from Step 2 — used by both the Terraform and ARC deploy pipelines |
| `AWS_REGION` | e.g. `eu-central-1` |
| `APP_ID` | App ID from Step 1 |
| `APP_INSTALLATION_ID` | Installation ID from Step 1 |
| `APP_PRIVATE_KEY` | Full PEM content of the private key from Step 1 |

> **Note:** The OIDC role from Step 2 needs broad permissions (EKS, EC2, IAM, Secrets Manager) to create infrastructure via Terraform.

**After `terraform apply` completes**, the outputs (cluster name, region) are printed automatically — use them for the GitHub Actions secrets in Step 4.

---

### 🟠 Step 4 — Set GitHub Actions secrets

Go to **GitHub → your repo → Settings → Secrets and variables → Actions → New repository secret** and add:

| Secret | Value |
|--------|-------|
| `AWS_IAM_ROLE_ARN` | ARN of the role created in Step 2, e.g. `arn:aws:iam::<ACCOUNT_ID>:role/github-actions-arc-role` |
| `AWS_REGION` | e.g. `eu-central-1` |
| `EKS_CLUSTER_NAME` | Your EKS cluster name |

> Do not add `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` — OIDC is used instead.

---

### 🟣 Step 5 — Install the Renovate GitHub App (optional but recommended)

Renovate automatically opens PRs when a new ARC chart version is released, which then triggers the deploy-arc.yaml pipeline.

1. Go to [github.com/apps/renovate](https://github.com/apps/renovate)
2. Click **Install** and grant access to this repository

Dependabot (for GitHub Actions version updates) is built into GitHub and requires no installation.

---

## ✅ What happens automatically after you push to main

There are two pipelines. Which ones run depends on what files you change:

**`deploy-terraform.yaml`** — runs when `terraform/**` changes:
1. Authenticates to AWS via OIDC (using `AWS_IAM_ROLE_ARN` from Step 2)
2. Runs `terraform init` and `terraform plan`
3. Applies the plan — provisions EKS, VPC, IAM roles, Secrets Manager secret, ESO, SecretStore, ExternalSecret
4. Prints outputs (cluster name, role ARN, region) to use as GitHub Actions secrets

**`deploy-arc.yaml`** — runs when `arc-system/**`, `versions.env`, `install.sh`, or the workflow file changes:
1. Checks out the repo
2. Loads the pinned chart version from `versions.env`
3. Authenticates to AWS via OIDC (using `AWS_IAM_ROLE_ARN` from Step 2)
4. Configures kubectl against your EKS cluster
5. Applies RBAC (`arc-system/rbac.yaml`)
6. Applies NetworkPolicies (`arc-system/network-policy.yaml`)
7. Installs the ARC controller via Helm
8. Installs the runner scale set via Helm
9. Applies ServiceMonitors (`arc-system/service-monitor.yaml`)
10. Verifies the rollout

**Version updates are also automated:**
- Renovate opens a PR when a new ARC chart version is released → merge the PR → pipeline deploys the new version
- Dependabot opens weekly PRs for GitHub Actions version bumps in workflow files

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

## Architecture overview

```
arc-runner-controller repo          CI/CD Cluster (EKS)
─────────────────────────           ───────────────────────────
deploy-arc.yaml          ────────►  arc-system  (controller)
arc-system/values        ────────►  arc-runners (runners)
                                            │
                                            │ runners execute jobs
                                            ▼
                                    Your other repos
                                    (app code, etc.)
                                            │
                                            │ deploy to
                                            ▼
                                    Production Cluster (EKS)
                                    ─────────────────────────
                                    Your actual app workloads
```

- **This repo** — manages CI/CD infrastructure only
- **Other repos** — use `runs-on: arc-runner-set` to run their pipelines on these runners
- **Production cluster** — completely separate, only receives deployments from those pipelines

---

## Using ARC runners in other repositories

Any repository under `getdzidon` can use these runners:

```yaml
jobs:
  build:
    runs-on: arc-runner-set   # matches runnerScaleSetName in arc-runner-scale-set-values.yaml
    steps:
      - uses: actions/checkout@v6
      - run: echo "Running on ARC runner!"
```

Full deploy example (in your app repo, not this repo):

```yaml
# .github/workflows/deploy-app.yaml
name: Deploy App

on:
  push:
    branches: [main]

permissions:
  contents: read
  id-token: write

jobs:
  deploy:
    runs-on: arc-runner-set

    steps:
      - uses: actions/checkout@v6

      - name: Authenticate to AWS via OIDC
        uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: ${{ secrets.AWS_IAM_ROLE_ARN }}   # IAM role for PRODUCTION cluster
          aws-region: ${{ secrets.AWS_REGION }}

      - name: Configure kubectl for Production Cluster
        run: |
          aws eks update-kubeconfig \
            --region ${{ secrets.AWS_REGION }} \
            --name ${{ secrets.PROD_EKS_CLUSTER_NAME }}

      - name: Deploy to Production
        run: |
          kubectl apply -f k8s/
          kubectl rollout status deployment/my-app -n my-app --timeout=120s
```

Required secrets in your app repo:

| Secret | Description |
|--------|-------------|
| `AWS_IAM_ROLE_ARN` | IAM role with access to the **production** EKS cluster (different from the CI role) |
| `AWS_REGION` | e.g. `eu-central-1` |
| `PROD_EKS_CLUSTER_NAME` | Your production cluster name |

---

## Autoscaling

| Setting | Value | Description |
|---------|-------|-------------|
| `minRunners` | 1 | Always-warm runner pod |
| `maxRunners` | 10 | Hard cap; increase for burst workloads |
| Scale trigger | Queued jobs | ARC scales up when jobs are waiting |
| Runner lifecycle | Ephemeral | Pod is destroyed after each job |

To change limits, edit `arc-system/arc-runner-scale-set-values.yaml` and push to `main`.

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

## RBAC

Runner pods use a dedicated least-privilege ServiceAccount (`arc-runner-sa`) defined in `arc-system/rbac.yaml`:

| Resource | Verbs |
|----------|-------|
| pods | get, list, watch, create, delete |
| pods/log | get, list, watch |
| secrets | get, list |
| jobs (batch) | get, list, watch, create, delete |

---

## Network isolation

`arc-system/network-policy.yaml` applies four policies to the `arc-runners` namespace:

| Policy | Effect |
|--------|--------|
| `arc-runners-deny-ingress` | Blocks all inbound traffic to runner pods by default |
| `arc-runners-allow-dns` | Allows UDP/TCP port 53 for DNS resolution |
| `arc-runners-allow-egress-https` | Allows outbound HTTPS (443) only |
| `arc-runners-allow-controller` | Allows inbound traffic from `arc-system` namespace only |

---

## Observability

`arc-system/service-monitor.yaml` defines two Prometheus ServiceMonitors:

| Monitor | Namespace | What it scrapes |
|---------|-----------|-----------------|
| `arc-controller-metrics` | arc-system | ARC controller `/metrics` every 30s |
| `arc-runner-set-metrics` | arc-runners | Runner scale set listener `/metrics` every 30s |

Requires [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) or standalone Prometheus Operator. The `release: prometheus` label must match your Prometheus Operator's `serviceMonitorSelector`.

---

## Secret template reference

`arc-system/github-app-secret.yaml.tpl` shows the exact shape of the `arc-github-app-secret` Kubernetes secret that ARC expects. It contains placeholder values only and is never applied directly. Never populate it with real values.

---

## .gitignore

| Pattern | What it blocks |
|---------|----------------|
| `*.pem` | GitHub App private key files |
| `*.key` | Any raw key files |
| `.env` | Local environment variable files |
| `arc-system/github-app-secret.yaml` | Plain (unencrypted) secret manifests |

---

## Local bootstrap (alternative to the pipeline)

`install.sh` is a local-only script. It is **not called by the pipeline** — `deploy-arc.yaml` runs its own Helm and kubectl commands directly.

Run `install.sh` manually from your machine **instead of** pushing to `main`, for example when:
- You want to bootstrap ARC on a cluster that is not yet reachable by GitHub Actions
- You are testing locally before setting up the pipeline
- You do not want to use the GitOps pipeline at all

Run it after completing Steps 1–4 (GitHub App, OIDC, secrets, etc.) with your kubeconfig pointing at the target cluster:

```bash
export GITHUB_APP_ID=<app-id>
export GITHUB_APP_INSTALLATION_ID=<installation-id>
export GITHUB_APP_PRIVATE_KEY_PATH=/path/to/private-key.pem

chmod +x install.sh
./install.sh
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
Ensure the `arc-system` namespace has the label `kubernetes.io/metadata.name=arc-system`.

**Helm OCI pull fails**
```bash
helm registry login ghcr.io -u <github-username> --password-stdin <<< <github-pat>
```
Requires a GitHub PAT with `read:packages` scope.

**ServiceMonitor not scraping**
```bash
kubectl get servicemonitor -n arc-system -o yaml
```
Ensure the `release: prometheus` label matches your Prometheus Operator's `serviceMonitorSelector`.

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
