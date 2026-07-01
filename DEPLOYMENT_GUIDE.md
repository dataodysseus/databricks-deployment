# Deploying Databricks on GCP with Terraform — A Complete Field Guide

> A step-by-step, battle-tested guide for standing up a Databricks workspace on Google Cloud
> using this Terraform codebase. It covers the architecture, the **exact IAM prerequisites**
> (the part that trips everyone up), the deployment flow, and a troubleshooting table built
> from every error we actually hit during the first deployment.

---

## 1. What you'll end up with

A fully networked, single-region Databricks workspace running on GCP, with:

- A dedicated **VPC + subnet** (with GKE pod/service secondary ranges), **Cloud NAT**, and **firewall rules** scoped to the Databricks control plane.
- **Service accounts** and IAM for the GKE nodes and DBFS/Unity Catalog storage.
- A **GCS bucket** for DBFS root storage.
- The **Databricks workspace** itself, registered to your Databricks account and attached to the VPC.

**Example output from a real run:**

```
workspace_id  = <WORKSPACE_ID>
workspace_url = "https://<WORKSPACE_ID>.9.gcp.databricks.com"
```

---

## 2. Architecture at a glance

```
                          ┌─────────────────────────────────────────┐
                          │   Databricks Account Console (GCP)        │
                          │   accounts.gcp.databricks.com             │
                          │   - holds your Databricks Account ID      │
                          │   - SA must be an Account Admin here       │
                          └───────────────────┬───────────────────────┘
                                              │ (account-level API:
                                              │  networks, workspaces,
                                              │  permission assignments)
                                              ▼
┌──────────────────────────── GCP Project ───────────────────────────────────┐
│                                                                              │
│   VPC ── Subnet (nodes) ── secondary ranges: pods, services                  │
│    │         │                                                               │
│    │         └── Cloud Router ── Cloud NAT  (egress to PyPI, etc.)            │
│    │                                                                          │
│   Firewalls: allow-internal (VPC) + allow-cp (35.199.224.0/19 control plane) │
│                                                                              │
│   Service Accounts:                                                          │
│     • databricks-gke-node-<env>   (logging, monitoring, storage, artifacts)  │
│     • databricks-storage-<env>    (DBFS / Unity Catalog storage)             │
│                                                                              │
│   GCS bucket: databricks-dbfs-<project>-<env>   (DBFS root, versioned)        │
│                                                                              │
│   Databricks Workspace  ──►  runs compute on GKE inside this VPC             │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. The codebase

```
databricks-gcp-deployment/
├── main.tf                      # Providers (google + databricks) and module wiring
├── variables.tf                 # Root variables (project, region, account ID, CIDRs…)
├── outputs.tf                   # workspace_url, workspace_id, VPC/subnet IDs, SA emails
├── workspace_access.tf          # Assigns users to the workspace (entitlements)
├── environments/
│   └── dev/dev.tfvars           # Per-environment values
├── scripts/
│   └── bootstrap.sh             # One-time: gcloud auth, enable APIs, terraform init
└── modules/
    ├── gcp-networking/          # VPC, subnet, NAT, firewalls
    ├── gcp-iam/                 # SAs, project roles, DBFS bucket, API enablement
    └── databricks-workspace/    # databricks_mws_networks + databricks_mws_workspaces
```

### Module responsibilities

| Module | Creates |
|--------|---------|
| `gcp-networking` | `google_compute_network`, `google_compute_subnetwork` (with `pods`/`services` secondary ranges), `google_compute_router`, `google_compute_router_nat`, two firewalls (internal + control-plane `35.199.224.0/19`) |
| `gcp-iam` | GKE-node SA + roles, storage SA + roles, workload-identity binding, DBFS GCS bucket, and **enables the 10 required GCP APIs** |
| `databricks-workspace` | `databricks_mws_networks` (registers the VPC/subnet with Databricks) → `databricks_mws_workspaces` (creates the workspace) |

---

## 4. The authentication model (read this before you start)

This is the single most important section. There are **two distinct identities** at play:

1. **Your human GCP identity** (e.g. `you@gmail.com`) — what `gcloud` is logged in as. It provides the *base* Application Default Credentials (ADC).
2. **A Databricks "automation" service account** (e.g. `your-automation-sa@<project>.iam.gserviceaccount.com`) — the identity Databricks **impersonates** to create networks/workspaces and to provision IAM in your project. This SA must be a **Databricks Account Admin**.

The Databricks provider uses **Google service-account impersonation** ("google-id" auth):

```
your ADC  ──(impersonate)──►  automation SA  ──►  Databricks Account API
```

This is driven by three environment variables (NOT hard-coded in the `.tf` files):

```bash
export DATABRICKS_HOST="https://accounts.gcp.databricks.com"
export DATABRICKS_ACCOUNT_ID="<your-databricks-account-id>"
export DATABRICKS_GOOGLE_SERVICE_ACCOUNT="<automation-sa>@<project>.iam.gserviceaccount.com"
```

> ⚠️ **Get the Account ID right.** It comes from the Databricks **account console**, not GCP.
> A wrong account ID authenticates successfully (you get a token) but every API call returns
> `403 Invalid Request`. The value in `environments/dev/dev.tfvars` is the source of truth —
> make sure your `DATABRICKS_ACCOUNT_ID` env var matches it.

---

## 5. Prerequisites

### Tooling
| Tool | Install |
|------|---------|
| `gcloud` CLI | https://cloud.google.com/sdk/docs/install |
| Terraform ≥ 1.5 | https://developer.hashicorp.com/terraform/install |
| `jq` (optional) | `brew install jq` |
| Databricks CLI (for access mgmt) | `brew install databricks` |

### Accounts
- A **GCP project** with billing enabled (this deployment used `your-gcp-project-id`).
- A **Databricks account on GCP** (subscribe via GCP Marketplace). Note its **Account ID** from `accounts.gcp.databricks.com`.
- An **automation service account** in the GCP project that is registered as an **Account Admin** in the Databricks account console.

---

## 6. ⭐ The IAM prerequisites (now codified in Terraform)

> ✅ **These grants are now applied automatically by `modules/gcp-iam`** — you no longer
> run the `gcloud` commands below by hand. Set two values in your tfvars and `terraform apply`
> handles the rest:
> ```hcl
> automation_service_account_email = "your-automation-sa@your-gcp-project-id.iam.gserviceaccount.com"
> terraform_admin_principals       = ["user:you@gmail.com"]   # identity you run terraform as
> ```
> **One bootstrap floor remains:** the identity running the *first* `terraform apply` must
> already be a **Project Owner** (or hold `roles/resourcemanager.projectIamAdmin` +
> `roles/iam.serviceAccountAdmin`). You can't grant IAM without permission to set IAM policy —
> that's irreducible. After that, a clean deploy needs **zero manual IAM commands**.
>
> The `gcloud` commands below are retained as reference / manual fallback and document exactly
> what the Terraform resources do.

The deployment will fail at three different points if these grants are missing. Replace the placeholders with your values.

```bash
PROJECT="your-gcp-project-id"
SA="your-automation-sa@${PROJECT}.iam.gserviceaccount.com"
ME="you@gmail.com"   # the human identity running terraform
```

### 6a. Let YOUR identity impersonate the automation SA
Without this you get: *"cannot configure default credentials"*.

```bash
gcloud iam service-accounts add-iam-policy-binding "$SA" \
  --member="user:${ME}" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --project="$PROJECT"
```

### 6b. Give the automation SA the project permissions Databricks needs
During workspace creation Databricks acts **as** this SA to create custom IAM roles and bind its managed service accounts. Without these you get: *"Insufficient permissions … iam.roles.create, … resourcemanager.projects.setIamPolicy, … iam.serviceAccounts.setIamPolicy"*.

```bash
for ROLE in \
  roles/iam.roleAdmin \
  roles/resourcemanager.projectIamAdmin \
  roles/iam.serviceAccountAdmin ; do
    gcloud projects add-iam-policy-binding "$PROJECT" \
      --member="serviceAccount:${SA}" \
      --role="$ROLE" --condition=None
done
```

> **Why three roles?**
> - `roles/iam.roleAdmin` → `iam.roles.create/update/delete/get`
> - `roles/resourcemanager.projectIamAdmin` → `resourcemanager.projects.get/setIamPolicy`
> - `roles/iam.serviceAccountAdmin` → `iam.serviceAccounts.get/setIamPolicy`
>
> IAM grants take ~30–60s to propagate. If a re-run still fails on permissions, wait and retry.

> ✅ **Reproducibility:** these grants are codified in `modules/gcp-iam`
> (`google_project_iam_member.automation_sa_roles` and
> `google_service_account_iam_member.automation_sa_token_creator`). A fresh environment does
> not repeat these manual steps — set the two tfvars values noted at the top of this section.

---

## 7. Deploy

### Step 1 — Bootstrap (one time)
```bash
cd databricks-gcp-deployment
./scripts/bootstrap.sh
```
This runs `gcloud auth login --update-adc`, `gcloud auth application-default login`, enables the required APIs, and runs `terraform init`.

### Step 2 — Set the Databricks env vars
```bash
export DATABRICKS_HOST="https://accounts.gcp.databricks.com"
export DATABRICKS_ACCOUNT_ID="$(grep databricks_account_id environments/dev/dev.tfvars | cut -d'"' -f2)"
export DATABRICKS_GOOGLE_SERVICE_ACCOUNT="your-automation-sa@your-gcp-project-id.iam.gserviceaccount.com"
```
(Deriving `DATABRICKS_ACCOUNT_ID` from the tfvars guarantees they match — see the warning in §4.)

### Step 3 — Plan & apply
```bash
terraform plan  -var-file=environments/dev/dev.tfvars
terraform apply -var-file=environments/dev/dev.tfvars
```
Workspace creation takes ~1–5 minutes (timeout is 30m). On success:
```bash
terraform output workspace_url
```

---

## 8. Grant yourself workspace access (required to log in)

Creating the workspace does **not** give you access to it. Authenticating via Google SSO only proves you're an account *member*; you also need a per-workspace **entitlement**. Otherwise the UI shows:

> *"You do not have permission to access this page in workspace … you are assigned to the workspace and have the 'Workspace access' entitlement."*

This repo handles it declaratively in `workspace_access.tf`:

```hcl
data "databricks_user" "admin" {
  provider  = databricks.accounts
  user_name = "you@gmail.com"
}

resource "databricks_mws_permission_assignment" "admin" {
  provider     = databricks.accounts
  workspace_id = module.databricks_workspace.workspace_id
  principal_id = data.databricks_user.admin.id
  permissions  = ["ADMIN"]   # use ["USER"] for non-admins
}
```

Apply it:
```bash
terraform apply -var-file=environments/dev/dev.tfvars \
  -target=databricks_mws_permission_assignment.admin
```

To onboard more people, duplicate the `data` + `resource` pair per email (or refactor to a `for_each` over a user list).

---

## 9. Accessing the workspace

### Web UI
Open the workspace URL and sign in with **the exact Google email you were assigned**:
```
https://<workspace_id>.<n>.gcp.databricks.com
```
If you still see the permission error right after assignment, **fully sign out and back in** — entitlement changes need a fresh session.

### CLI
```bash
brew install databricks
databricks auth login --host https://<workspace_id>.<n>.gcp.databricks.com
databricks current-user me
databricks clusters list
```

### API (automation, as the SA)
```bash
TOKEN=$(gcloud auth print-identity-token \
  --impersonate-service-account=your-automation-sa@your-gcp-project-id.iam.gserviceaccount.com \
  --audiences=https://<workspace_id>.<n>.gcp.databricks.com)
curl -s -H "Authorization: Bearer $TOKEN" \
  https://<workspace_id>.<n>.gcp.databricks.com/api/2.0/clusters/list
```

---

## 10. Troubleshooting — every error we hit, and the fix

| Symptom | Root cause | Fix |
|---------|-----------|-----|
| `cannot create mws workspaces: … cannot configure default credentials` | Your identity can't impersonate the automation SA | Grant yourself `roles/iam.serviceAccountTokenCreator` on the SA (§6a) |
| `cannot create mws networks: Invalid Request` (HTTP **403**), token exchange returns 200 | **Wrong `DATABRICKS_ACCOUNT_ID`** — auth works, account authz doesn't | Use the Account ID from `dev.tfvars` / account console; ensure the env var matches (§4) |
| `cannot create mws networks: Invalid Request` with `vpc_id` like `projects/.../global/networks/...` | Network refs sent as **GCP self-links** instead of bare names | `main.tf` must pass `module.gcp_networking.vpc_name` / `subnet_name` (not `vpc_id`/`subnet_id`) — see §11 |
| `Insufficient permissions … iam.roles.create, … projects.setIamPolicy` | SA lacks role/project-IAM admin | Grant `roles/iam.roleAdmin` + `roles/resourcemanager.projectIamAdmin` (§6b) |
| `Insufficient permissions … iam.serviceAccounts.getIamPolicy/setIamPolicy` | SA can't manage IAM on *other* service accounts | Grant **project-level** `roles/iam.serviceAccountAdmin` (§6b) |
| UI: *"You do not have permission to access this page in workspace …"* | Authenticated but no per-workspace entitlement | Add `databricks_mws_permission_assignment` (§8), then sign out/in |
| `Error acquiring the state lock` | A previous run left a stale lock | `terraform force-unlock <LOCK_ID>` (ID is in the error) |
| destroy: `network resource ... is already being used by .../firewalls/db-...` | Databricks left a `db-*` firewall rule in your VPC (untracked by TF) | Delete the orphan rule(s) then re-run destroy — or just use `./scripts/teardown.sh` (§12) |

---

## 11. Critical code detail: VPC/subnet names, not self-links

`databricks_mws_networks.gcp_network_info` expects **bare resource names**, e.g. `databricks-vpc-dev`, **not** GCP self-links like `projects/<p>/global/networks/databricks-vpc-dev`. The networking module exposes both forms:

```hcl
# modules/gcp-networking/outputs.tf
output "vpc_id"     { value = google_compute_network.databricks_vpc.id }    # self-link  ✗ for Databricks
output "vpc_name"   { value = google_compute_network.databricks_vpc.name }  # bare name  ✓
output "subnet_id"  { value = google_compute_subnetwork.databricks_subnet.id }
output "subnet_name"{ value = google_compute_subnetwork.databricks_subnet.name }
```

`main.tf` **must** wire the `*_name` outputs into the workspace module:

```hcl
module "databricks_workspace" {
  # ...
  network_id = module.gcp_networking.vpc_name      # ✓ name
  subnet_id  = module.gcp_networking.subnet_name   # ✓ name
}
```

---

## 12. Teardown

**Use the script — it handles the firewall quirk automatically:**
```bash
./scripts/teardown.sh dev
```
It sets the auth env vars from the tfvars, runs `terraform destroy`, and — if the
VPC delete is blocked — deletes the leftover Databricks firewall rule(s) and retries.

### ⚠️ The orphaned-firewall quirk (why plain `terraform destroy` fails)

Databricks provisions firewall rule(s) **inside your customer-managed VPC** that are
**not** in Terraform state (their names start with `db-`, e.g.
`db-databricks-vpc-subnet-dev-ingress`). Terraform destroys everything else, then
fails on the very last resource — the VPC — with:

```
Error: Error waiting for Deleting Network: The network resource
'projects/<p>/global/networks/databricks-vpc-dev' is already being used by
'projects/<p>/global/firewalls/db-databricks-vpc-subnet-dev-ingress'
```

**Manual fix** (what the script automates):
```bash
# 1. Find the orphaned rules on the VPC
gcloud compute firewall-rules list --project your-gcp-project-id \
  --filter="network~databricks-vpc-dev" --format="value(name)"

# 2. Delete them
gcloud compute firewall-rules delete db-databricks-vpc-subnet-dev-ingress \
  --project your-gcp-project-id --quiet

# 3. Re-run destroy to remove the VPC and clear state
export DATABRICKS_GOOGLE_SERVICE_ACCOUNT="your-automation-sa@your-gcp-project-id.iam.gserviceaccount.com"
terraform destroy -var-file=environments/dev/dev.tfvars
```

Confirm it's clean: `terraform state list` should return nothing.

### Notes
- Non-prod DBFS buckets use `force_destroy = true` (prod is guarded), so bucket
  contents are deleted on teardown.
- The manual IAM grants from §6 and the enabled APIs are **not** managed by
  Terraform and remain after teardown (so the next deploy stays fast).
- **Re-deploy creates a NEW workspace ID/URL** — the old
  `https://<id>.<n>.gcp.databricks.com` does not come back.

---

## 13. Quick-start checklist (TL;DR)

- [ ] GCP project + billing; Databricks GCP account; note the **Account ID**
- [ ] Automation SA exists and is a **Databricks Account Admin**
- [ ] §6a — you can impersonate the SA (`serviceAccountTokenCreator`)
- [ ] §6b — SA has `roleAdmin` + `projectIamAdmin` + `serviceAccountAdmin` on the project
- [ ] `./scripts/bootstrap.sh`
- [ ] Export `DATABRICKS_HOST` / `DATABRICKS_ACCOUNT_ID` (matches tfvars) / `DATABRICKS_GOOGLE_SERVICE_ACCOUNT`
- [ ] Confirm `main.tf` uses `vpc_name` / `subnet_name` (§11)
- [ ] `terraform apply -var-file=environments/dev/dev.tfvars`
- [ ] Add yourself via `workspace_access.tf` and apply (§8)
- [ ] Sign out/in, open `workspace_url`, you're in 🎉

**Deploy / tear down (after first-time setup):**
- [ ] Deploy:   `./scripts/deploy.sh dev`
- [ ] Tear down: `./scripts/teardown.sh dev`  (auto-handles the `db-*` firewall quirk, §12)
