# Databricks on GCP — Terraform Deployment

Deploy a Databricks workspace on Google Cloud Platform using Terraform.

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

| Resource | Approx. monthly cost |
|----------|---------------------|
| GKE cluster (e2-standard-4 × 2) | ~$120 |
| Cloud NAT | ~$5 |
| GCS bucket (DBFS) | ~$2 |
| Databricks DBU usage | varies by workload |

> **Tip:** Terminate clusters when not in use to minimize DBU costs.
