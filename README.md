# GitHub Actions Runner Controller (ARC)

Self-hosted ephemeral runners on Kubernetes using the official [ARC](https://github.com/actions/actions-runner-controller) Helm charts.

GitHub account: **getdzidon** — `https://github.com/getdzidon`

---

## How it works

```
Manual steps (one-time)  →  push to main  →  deploy-terraform.yaml  →  deploy-arc.yaml  →  ARC is live
```

Two pipelines run in sequence after the one-time manual steps:

1. `deploy-terraform.yaml` — provisions all AWS infrastructure via Terraform (VPC, EKS, IAM, Secrets Manager, ESO, SecretStore, ExternalSecret)
2. `deploy-arc.yaml` — installs the ARC controller and runner scale set onto the cluster via Helm

Once both complete, runners are live and any repo under `getdzidon` org can use `runs-on: arc-runner-set`.

---

## Project structure

```
arc-runner-controller/
├── .github/
│   ├── workflows/
│   │   ├── deploy-terraform.yaml         # Pipeline — provisions AWS infra + EKS via Terraform
│   │   ├── deploy-arc.yaml               # Pipeline — deploys ARC onto the cluster
│   │   └── test-arc-runners.yaml          # CI pipeline that runs ON ARC runners
│   └── dependabot.yml
├── arc-system/
│   ├── arc-controller-values.yaml        # Helm values for the ARC controller
│   ├── arc-runner-scale-set-values.yaml  # Helm values + autoscaling config
│   ├── rbac.yaml                         # ServiceAccount, Role, RoleBinding
│   ├── network-policy.yaml               # NetworkPolicies for runner isolation
│   ├── service-monitor.yaml              # Prometheus ServiceMonitors
│   ├── secret-store.yaml                 # ESO SecretStore (applied by Terraform)
│   ├── external-secret.yaml              # ESO ExternalSecret (applied by Terraform)
│   └── github-app-secret.yaml.tpl        # Secret shape reference — never commit real values
├── terraform/
│   ├── providers.tf                      # Terraform block, S3 backend, AWS/Helm/kubectl providers
│   ├── vpc.tf                            # VPC: 10.0.0.0/16, 2 AZs, private + public subnets, NAT
│   ├── eks.tf                            # EKS 1.35, managed node group (t3.medium), vpc-cni, kube-proxy, coredns
│   ├── iam.tf                            # ESO IRSA role (ESO-ARC-Role) + policy
│   ├── secrets.tf                        # AWS Secrets Manager secret (arc/github-app-secret)
│   ├── eso.tf                            # ESO Helm release, CRD wait, namespace, ServiceAccount, SecretStore, ExternalSecret
│   ├── variables.tf                      # Input variables
│   ├── outputs.tf                        # Outputs: cluster name, region
│   └── terraform.tfvars                  # Your values — blocked by .gitignore, never commit
├── versions.env                          # Pinned ARC chart version (updated by Renovate)
├── renovate.json                         # Automated dependency update config
├── install.sh                            # Local bootstrap script (alternative to the pipeline)
├── .gitignore
└── README.md
```

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| aws cli | ≥ 2.x | [docs](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| terraform | ≥ 1.6 | [docs](https://developer.hashicorp.com/terraform/install) |

> Everything else (kubectl, helm, EKS cluster) is provisioned automatically by Terraform and the pipelines.

---

## ⚠️ Manual steps — do these once, in order, before pushing to `main`

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
5. Click **Create GitHub App** — note the `App ID` at the top of the next page

**Generate a private key:**

1. Scroll down to **Private keys** → click **Generate a private key**
2. A `.pem` file downloads — keep it safe, you cannot re-download it

**Install the App and get the Installation ID:**

1. Left sidebar → **Install App** → **Install** next to your account
2. Choose *All repositories* or select specific repos → click **Install**
3. After install you are redirected to `https://github.com/settings/installations/<INSTALLATION_ID>`
4. Note the number at the end — that is your `Installation ID`

You now have: `APP_ID`, `INSTALLATION_ID`, `/path/to/private-key.pem`

---

### 🟢 Step 2 — Create the GitHub Actions OIDC provider and IAM role

The deploy pipelines authenticate to AWS via OIDC — no static credentials. The OIDC provider must exist in your AWS account before anything else can run — both the `deploy-arc.yaml` pipeline and Terraform depend on it.

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

# 4. Attach permissions (EKS, EC2, IAM, Secrets Manager needed for Terraform)
aws iam attach-role-policy \
  --role-name github-actions-arc-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
```

Note the role ARN — you need it in Step 4.

---

### 🟠 Step 3 — Create the S3 bucket for Terraform remote state if you do not have one

Terraform stores state in S3. The bucket must exist before `terraform init` can run.

```bash
aws s3api create-bucket \
  --bucket <YOUR_BUCKET_NAME> \
  --region eu-central-1 \
  --create-bucket-configuration LocationConstraint=eu-central-1

aws s3api put-bucket-versioning \
  --bucket <YOUR_BUCKET_NAME> \
  --versioning-configuration Status=Enabled
```

Then update `terraform/providers.tf` with your bucket name:

```hcl
backend "s3" {
  bucket = "<YOUR_BUCKET_NAME>"
  key    = "arc-runner-controller/terraform.tfstate"
  region = "eu-central-1"
}
```

The bucket name in this repo is `deebest-tf-state-bucket` — replace it with your own.

---

### 🟡 Step 4 — Set GitHub Actions secrets

Go to **GitHub → your repo → Settings → Secrets and variables → Actions → New repository secret** and add:

| Secret | Value |
|--------|-------|
| `AWS_IAM_ROLE_ARN` | ARN of the role from Step 2, e.g. `arn:aws:iam::<ACCOUNT_ID>:role/github-actions-arc-role` |
| `AWS_REGION` | `eu-central-1` |
| `EKS_CLUSTER_NAME` | Your desired cluster name, e.g. `arc-ci-cluster` |
| `CLUSTER_ADMIN_USERNAME` | Your IAM username, e.g. `terraform-user` |
| `APP_ID` | App ID from Step 1 |
| `APP_INSTALLATION_ID` | Installation ID from Step 1 |
| `APP_PRIVATE_KEY` | Full PEM content of the private key from Step 1 |

> Do not add `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` — OIDC is used instead.

---

### 🟣 Step 5 — Install the Renovate GitHub App (optional but recommended)

Renovate automatically opens PRs when a new ARC chart version is released, which then triggers the deploy-arc.yaml pipeline.

1. Go to [github.com/apps/renovate](https://github.com/apps/renovate)
2. Click **Install** and grant access to this repository

Dependabot (for GitHub Actions version updates) is built into GitHub and requires no installation.

---

## ✅ What happens automatically after you push to `main`

### `deploy-terraform.yaml` — triggered by changes to `terraform/**`

Runs `terraform init → validate → plan → apply` and prints outputs. Provisions:

| Resource | Details |
|----------|---------|
| VPC | `10.0.0.0/16`, 2 AZs (`eu-central-1a/b`), 2 private + 2 public subnets, single NAT gateway |
| EKS cluster | Kubernetes 1.35, public + private endpoint, IRSA enabled |
| EKS add-ons | `vpc-cni`, `kube-proxy` (with cluster), `coredns` (after node group) |
| Managed node group | `t3.medium`, min 1 / max 3 / desired 2, private subnets |
| IAM role | `ESO-ARC-Role` — IRSA role for ESO to read Secrets Manager |
| Secrets Manager | `arc/github-app-secret` — stores `github_app_id`, `github_app_installation_id`, `github_app_private_key` |
| ESO | External Secrets Operator installed via Helm in `external-secrets` namespace |
| `arc-runners` namespace | Created by Terraform before any resources target it |
| ESO ServiceAccount | `external-secrets` SA in `arc-runners` with IRSA annotation |
| SecretStore | `aws-secret-store` in `arc-runners` — connects ESO to Secrets Manager via IRSA |
| ExternalSecret | `arc-github-app-secret` in `arc-runners` — syncs the GitHub App credentials into a K8s secret every 1h |

The pipeline can also be triggered manually via **workflow_dispatch** with `action: destroy` to tear everything down.

### `deploy-arc.yaml` — triggered by changes to `arc-system/**`, `versions.env`, `install.sh`

Deploys ARC onto the cluster that Terraform provisioned:

1. Loads pinned chart version from `versions.env` (currently `0.9.3`)
2. Authenticates to AWS via OIDC
3. Configures kubectl against the EKS cluster
4. Applies RBAC (`arc-system/rbac.yaml`)
5. Applies NetworkPolicies (`arc-system/network-policy.yaml`)
6. `helm upgrade --install arc` — ARC controller in `arc-system`
7. `helm upgrade --install arc-runner-set` — runner scale set in `arc-runners`
8. Verifies rollout (dynamically discovers the controller deployment name)

The pipeline also supports `action: destroy` via workflow_dispatch to uninstall Helm releases and delete namespaces.

### Version updates are automated

- **Renovate** opens a PR when a new ARC chart version is released → merge → `deploy-arc.yaml` deploys it
- **Dependabot** opens weekly PRs for GitHub Actions version bumps in workflow files

---

## What Terraform creates end-to-end

```
module.vpc
  └── module.eks  (cluster + vpc-cni + kube-proxy add-ons)
        └── module.node_group  (t3.medium nodes — wait for CNI add-on first)
              └── aws_eks_addon.coredns  (needs nodes to schedule pods)
                    └── helm_release.eso  (External Secrets Operator)
                          └── time_sleep.wait_for_eso_crds  (30s for CRD registration)
                                └── kubectl_manifest.arc_runners_namespace
                                      └── kubectl_manifest.eso_service_account  (IRSA SA in arc-runners)
                                            └── kubectl_manifest.secret_store
                                                  └── kubectl_manifest.external_secret
```

Key design decisions:
- `vpc-cni` and `kube-proxy` are included in the EKS module — they go Active without nodes
- `coredns` is a separate `aws_eks_addon` with `depends_on = [module.node_group]` — it needs nodes to schedule pods
- ESO CRDs take ~30s to register after the Helm release completes — `time_sleep` handles this
- The `arc-runners` namespace is created by Terraform before the SecretStore and ExternalSecret target it
- The ESO ServiceAccount is created in `arc-runners` (not `external-secrets`) with the IRSA annotation — required because a namespace-scoped SecretStore cannot reference a ServiceAccount in a different namespace

---

## Verify installation

```bash
kubectl get pods -n arc-system                        # ARC controller
kubectl get autoscalingrunnerset -n arc-runners       # runner scale set
kubectl get pods -n arc-runners                       # runner pods (appear when jobs queue)
kubectl get externalsecret arc-github-app-secret -n arc-runners   # ESO sync status
kubectl get secret arc-github-app-secret -n arc-runners           # synced K8s secret
kubectl get networkpolicy -n arc-runners              # network policies
kubectl get rolebinding -n arc-runners                # RBAC
```

---

## Architecture overview

```
arc-runner-controller repo          CI/CD Cluster (EKS, eu-central-1)
─────────────────────────           ──────────────────────────────────
deploy-terraform.yaml    ────────►  VPC + EKS + IAM + Secrets Manager + ESO
deploy-arc.yaml          ────────►  arc-system  (ARC controller)
arc-system/values        ────────►  arc-runners (runner scale set)
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
| `AWS_IAM_ROLE_ARN` | IAM role with access to the production EKS cluster (different from the CI role) |
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

## Storage

Runners use the default mode (no `containerMode`) — each job runs directly in the runner container. No persistent volumes or storage classes are needed. Runner pods are ephemeral and destroyed after each job.

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

`arc-system/service-monitor.yaml` defines two Prometheus ServiceMonitors (disabled in the pipeline by default — uncomment the step to enable):

| Monitor | Namespace | What it scrapes |
|---------|-----------|-----------------|
| `arc-controller-metrics` | arc-system | ARC controller `/metrics` every 30s |
| `arc-runner-set-metrics` | arc-runners | Runner scale set listener `/metrics` every 30s |

Requires [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) or standalone Prometheus Operator. The `release: prometheus` label must match your Prometheus Operator's `serviceMonitorSelector`.

---

## Secret template reference

`arc-system/github-app-secret.yaml.tpl` shows the exact shape of the `arc-github-app-secret` Kubernetes secret that ARC expects. It contains placeholder values only and is never applied directly. Never populate it with real values.

---

## Secret flow

```
GitHub Actions secrets (APP_ID, APP_INSTALLATION_ID, APP_PRIVATE_KEY)
        │  (via TF_VAR_* env vars in deploy-terraform.yaml)
        ▼
terraform apply
        │
        ├── aws_secretsmanager_secret  →  arc/github-app-secret  (Secrets Manager)
        ├── aws_iam_role.eso           →  ESO-ARC-Role  (IRSA)
        ├── helm_release.eso           →  External Secrets Operator
        ├── kubectl_manifest.secret_store   →  SecretStore (arc-runners)
        └── kubectl_manifest.external_secret → ExternalSecret (arc-runners)
                                                        │  (synced every 1h)
                                                        ▼
                                              arc-github-app-secret  (K8s Secret)
                                                        │
                                                        ▼
                                              ARC controller reads it
```

---

## .gitignore

| Pattern | What it blocks |
|---------|----------------|
| `*.pem` | GitHub App private key files |
| `*.key` | Any raw key files |
| `.env` | Local environment variable files |
| `terraform.tfvars` | Terraform variable values |
| `arc-system/github-app-secret.yaml` | Plain (unencrypted) secret manifests |

---

## Local bootstrap (alternative to the pipeline)

`install.sh` performs the same Helm installs as `deploy-arc.yaml` but runs locally. Use it when you want to bootstrap ARC without pushing to `main`, or when the cluster is not yet reachable by GitHub Actions.

Run it after Terraform has provisioned the cluster, with your kubeconfig pointing at the target cluster:

```bash
export GITHUB_APP_ID=<app-id>
export GITHUB_APP_INSTALLATION_ID=<installation-id>
export GITHUB_APP_PRIVATE_KEY_PATH=/path/to/private-key.pem

chmod +x install.sh
./install.sh
```

---

## Uninstall

**Destroy ARC only** (via pipeline workflow_dispatch, `action: destroy`):
- Uninstalls `arc-runner-set` and `arc` Helm releases
- Deletes `arc-runners` and `arc-system` namespaces


**Destroy all infrastructure** (via pipeline workflow_dispatch on `deploy-terraform.yaml`, `action: destroy`):
- Runs `terraform destroy` — removes EKS, VPC, IAM roles, Secrets Manager secret, ESO

> If a Terraform apply partially fails, orphaned resources may exist in AWS but not in Terraform state. In that case, a full `destroy` + `apply` is the cleanest recovery path.

---

## Troubleshooting

**Controller pod is CrashLoopBackOff**
```bash
kubectl logs -n arc-system -l app.kubernetes.io/name=gha-runner-scale-set-controller
```
Most common cause: `arc-github-app-secret` is missing or in the wrong namespace. Check ESO sync status:
```bash
kubectl get externalsecret arc-github-app-secret -n arc-runners
```



**Runners not picking up jobs**
```bash
kubectl logs -n arc-runners -l app.kubernetes.io/name=arc-runner-set
```
Check that `githubConfigUrl` points to a specific **repository** (e.g. `https://github.com/user/repo`), not a user account URL. GitHub's runner registration API returns 404 for user-level URLs.



**Runner pods stuck in Pending or CrashLoopBackOff with IP errors**
```bash
kubectl get events -n arc-runners --field-selector reason=FailedCreatePodSandBox
```
If you see `failed to assign an IP address to container`, the vpc-cni has exhausted available IPs. This can happen after crash loops leave stale ENI allocations. Fix: restart the vpc-cni daemonset:
```bash
kubectl rollout restart daemonset/aws-node -n kube-system
kubectl delete ephemeralrunner --all -n arc-runners
```



**Terraform: "Addon already exists" or "cannot re-use a name that is still in use"**

This happens when a previous apply partially succeeded — the resource was created in AWS/Kubernetes but Terraform errored before recording it in state. Options:
- Use a Terraform `import` block to adopt the existing resource
- Or destroy everything and apply fresh (faster when multiple resources are orphaned)



**ESO SecretStore: "ServiceAccount not found"**

The SecretStore references a service account for IRSA auth. This SA must exist in the **same namespace** as the SecretStore (namespace-scoped). The ESO Helm chart creates its SA in the `external-secrets` namespace, not `arc-runners`. Terraform creates a dedicated SA with the IRSA annotation in `arc-runners` to solve this.



**ESO SecretStore: "resource is not valid for cluster"**

Two possible causes:
1. CRDs not ready yet — `time_sleep` (30s) handles this, but on slow clusters increase the duration in `eso.tf`
2. Wrong API version — the manifests use `external-secrets.io/v1` (not `v1beta1`)



**ESO SecretStore: "namespace not found"**

The `arc-runners` namespace must exist before the SecretStore can be created in it. Terraform must create the namespace explicitly before applying the SecretStore manifest.



**Node group CREATE_FAILED: unhealthy nodes**

Missing `vpc-cni` add-on. Nodes register but CNI never initializes → `NotReady`. Confirmed by:
```bash
kubectl get pods -n kube-system   # empty
aws eks list-addons --cluster-name arc-ci-cluster   # empty array
```
The EKS module in this repo includes `vpc-cni` and `kube-proxy` in `addons {}` to prevent this.



**CoreDNS stuck in Degraded**

CoreDNS requires nodes to schedule its pods. If installed at the same time as the node group, it will stay `Degraded` until the 20-minute Terraform timeout, then fail. Solution: install CoreDNS as a separate `aws_eks_addon` resource with `depends_on` pointing to the node group.



**EKS console shows "No Nodes" or kubectl returns "provide credentials"**

EKS access entries are managed in the EKS module via `access_entries`. If you recreate the cluster manually:
```bash
aws eks create-access-entry --cluster-name arc-ci-cluster \
  --principal-arn arn:aws:iam::<ACCOUNT_ID>:root --region eu-central-1
aws eks associate-access-policy --cluster-name arc-ci-cluster \
  --principal-arn arn:aws:iam::<ACCOUNT_ID>:root \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster --region eu-central-1
```


**Node group CREATE_FAILED: Unhealthy nodes in the kubernetes cluster**

This is almost always caused by missing EKS add-ons. The EKS Terraform module (`terraform-aws-modules/eks/aws` ~> 21.x) does **not** install add-ons by default. Without `vpc-cni`, nodes register but the CNI never initializes → `NetworkReady=false` → nodes stay `NotReady` → EKS reports "unhealthy" after a 33-minute timeout.

Diagnose:
```bash
aws eks update-kubeconfig --name arc-ci-cluster --region eu-central-1
kubectl get nodes                    # shows NotReady with "cni plugin not initialized"
kubectl get pods -n kube-system      # empty = no add-ons installed
aws eks list-addons --cluster-name arc-ci-cluster   # empty array confirms it
```

Fix: add `addons` block to the EKS module (note: the argument is `addons`, not `cluster_addons`):
```hcl
addons = {
  "vpc-cni"    = { most_recent = true }
  "kube-proxy" = { most_recent = true }
}
```

CoreDNS must be installed **after** the node group (it needs nodes to schedule pods on). See the Terraform deployment order section below.



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


## Terraform deployment order

The EKS Terraform module creates add-ons and node groups in parallel by default, which causes failures. This project splits them into separate resources with explicit dependencies:

```
module.eks (cluster + vpc-cni + kube-proxy)
        │
        ▼
module.node_group (nodes come up with CNI ready → Ready state)
        │
        ▼
aws_eks_addon.coredns (pods schedule onto healthy nodes → Active)
        │
        ▼
helm_release.eso (External Secrets Operator)
        │
        ▼
time_sleep.wait_for_eso_crds (30s for CRD registration)
        │
        ▼
kubectl_manifest.arc_runners_namespace
        │
        ▼
kubectl_manifest.eso_service_account (IRSA-annotated SA in arc-runners)
        │
        ▼
kubectl_manifest.secret_store
        │
        ▼
kubectl_manifest.external_secret
```

Key points:
- `vpc-cni` and `kube-proxy` go Active without nodes — safe to include in the EKS module
- `coredns` needs nodes — must be a separate resource that depends on the node group
- The node group is a separate sub-module (`eks-managed-node-group`) so it waits for add-ons
- ESO CRDs take ~30s to register after the Helm release completes
- The `arc-runners` namespace must be created before any resources that target it
- The ESO service account must be created in `arc-runners` (where the SecretStore lives) with the IRSA annotation — the Helm-installed SA lives in `external-secrets` and can't be referenced cross-namespace by a namespace-scoped SecretStore

---