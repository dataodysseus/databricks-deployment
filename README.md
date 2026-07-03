# Databricks on GCP — Terraform Deployment

Deploy a Databricks workspace on Google Cloud Platform using Terraform, from your
machine or fully automated via GitHub Actions.

## Documentation

| Doc | What it covers |
|-----|----------------|
| **README.md** (this file) | Overview, structure, quick start |
| **[CICD.md](CICD.md)** | GitHub Actions automation — WIF/OIDC auth, remote state, plan/apply/destroy, secrets model |
| **[DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md)** | Operational runbook, the IAM bootstrap floor (§6), teardown, troubleshooting |
| **[TERRAFORM_PRIMER.md](TERRAFORM_PRIMER.md)** | Terraform concepts, taught from this repo's code |
| **[bootstrap/README.md](bootstrap/README.md)** | One-time landing zone for a **new** GCP project (SA + IAM floor + WIF) |

## Project Details

| Field | Value |
|-------|-------|
| GCP Project ID | `your-gcp-project-id` |
| Databricks Account ID | `<DATABRICKS_ACCOUNT_ID>` |
| Default Region | `us-central1` |

---

## Project Structure

```
databricks-gcp-deployment/
├── main.tf                          # Root module — wires everything together
├── variables.tf                     # Root variable declarations
├── outputs.tf                       # Root outputs (workspace URL, IDs, etc.)
│
├── modules/
│   ├── gcp-networking/              # VPC, subnet, secondary ranges, NAT, firewall
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   │
│   ├── gcp-iam/                     # Service accounts, IAM roles, GCS bucket, API enablement
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   │
│   └── databricks-workspace/        # Databricks MWS network config + workspace resource
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
│
├── environments/
│   ├── dev/dev.tfvars               # Dev environment variable values
│   └── prod/prod.tfvars             # Prod environment variable values
│
└── scripts/
    └── bootstrap.sh                 # One-time auth + API enablement script
```

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Terraform | >= 1.5.0 | `brew install terraform` |
| gcloud CLI | latest | [Install guide](https://cloud.google.com/sdk/docs/install) |
| jq | any | `brew install jq` (optional) |

---

## Quick Start

### 1. Run the bootstrap script (one time only)

```bash
chmod +x scripts/bootstrap.sh
./scripts/bootstrap.sh
```

This will:
- Log you in to GCP with Application Default Credentials (ADC)
- Enable all required GCP APIs
- Run `terraform init`

### 2. Plan the deployment

```bash
terraform plan -var-file=environments/dev/dev.tfvars
```

### 3. Apply

```bash
terraform apply -var-file=environments/dev/dev.tfvars
```

Workspace creation takes **15–25 minutes** (GKE provisioning).

### 4. Get your workspace URL

```bash
terraform output workspace_url
```

---

## Manual Auth (if you skip bootstrap)

```bash
# Login interactively
gcloud auth login

# Set application default credentials (what Terraform uses)
gcloud auth application-default login

# Set your project
gcloud config set project your-gcp-project-id
```

---

## What Gets Created

### GCP Resources
- **VPC** — Custom VPC with private subnet and two secondary IP ranges (GKE pods + services)
- **Cloud NAT** — Allows private nodes to reach the internet
- **Firewall rules** — Internal traffic + Databricks control plane ingress
- **Service Accounts** — Two SAs: GKE nodes and DBFS/storage
- **IAM Bindings** — Minimal required roles for each SA
- **GCS Bucket** — DBFS root storage bucket with versioning

### Databricks Resources
- **MWS Network Config** — Registers your VPC with Databricks
- **Workspace** — Full Databricks workspace running on GKE

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  GCP Project: your-gcp-project-id                 │
│                                                      │
│  ┌──────────────────────────────────────────────┐   │
│  │  VPC: databricks-vpc-dev                     │   │
│  │                                              │   │
│  │  ┌────────────────────────────────────────┐  │   │
│  │  │  Subnet: 10.0.0.0/16                   │  │   │
│  │  │  ├── Pods:     10.1.0.0/16             │  │   │
│  │  │  └── Services: 10.2.0.0/20             │  │   │
│  │  │                                        │  │   │
│  │  │  ┌──────────────────────────────────┐  │  │   │
│  │  │  │  GKE Cluster (Databricks-managed)│  │  │   │
│  │  │  │  Private nodes, Public master    │  │  │   │
│  │  │  └──────────────────────────────────┘  │  │   │
│  │  └────────────────────────────────────────┘  │   │
│  │                                              │   │
│  │  Cloud NAT ──► Internet (PyPI, Maven, etc.)  │   │
│  └──────────────────────────────────────────────┘   │
│                                                      │
│  GCS Bucket: databricks-dbfs-your-gcp-project-id  │
└─────────────────────────────────────────────────────┘
         │
         │ HTTPS
         ▼
┌────────────────────────────────┐
│  Databricks Control Plane      │
│  accounts.gcp.databricks.com   │
│  Account: <ACCOUNT_ID>         │
└────────────────────────────────┘
```

---

## Environments

| Env | tfvars file | Workspace name |
|-----|-------------|----------------|
| dev | `environments/dev/dev.tfvars` | `databricks-gcp-dev` |
| prod | `environments/prod/prod.tfvars` | `databricks-gcp-prod` |

---

## Troubleshooting

### "Error: Workspace creation timed out"
GKE provisioning can take up to 30 min. Re-run `terraform apply` — it will resume where it left off.

### "Error 403: Required 'compute.networks.get' permission"
Your GCP account needs the `Editor` or `Owner` role, or the specific Databricks-required custom role. Run:
```bash
gcloud projects add-iam-policy-binding your-gcp-project-id \
  --member="user:YOUR_EMAIL" \
  --role="roles/editor"
```

### "databricks: cannot authenticate"
Ensure ADC is set: `gcloud auth application-default login`
Your email must be an admin in the Databricks account console (`accounts.gcp.databricks.com`).

### Destroy (cleanup)
```bash
terraform destroy -var-file=environments/dev/dev.tfvars
```

---

## Cost Estimate (dev, us-central1)

Of the ~32 resources deployed, most are **free** (VPC, subnet, router, firewall, service
accounts, IAM bindings, API enablement, and the Databricks network/permission resources).
The cost is concentrated in a handful of always-on items plus usage-based compute.

**Idle floor** — bills whether or not anyone uses the workspace:

| Resource | Approx. monthly cost |
|----------|---------------------|
| GKE cluster management fee (workspace runs on GKE) | ~$73 |
| GKE baseline node VMs (system pods) | ~$100–200 |
| Cloud NAT gateway | ~$32 + ~$0.045/GB processed |
| GCS bucket (DBFS root) storage | a few $ |
| **Idle floor total** | **~$200–300/mo** |

**Variable** — bills only while your clusters run (≈ $0 when all clusters are terminated):

| Resource | Cost |
|----------|------|
| Databricks DBUs (license) | ~$0.22–0.55/DBU, by tier + workload |
| Job/cluster node VMs | standard GCE compute rates |
| Network egress | ~$0.08–0.12/GB |

> **Not serverless:** the workspace's own GKE cluster bills continuously — idling a
> workspace overnight is **not** free. Terminate clusters to kill DBU/VM cost, and run
> `destroy` (or the GitHub Action's destroy) to remove the idle floor entirely.
>
> Figures are order-of-magnitude, us-central1, and vary with region/tier/usage. Confirm
> against the live GCP + Databricks pricing pages.
