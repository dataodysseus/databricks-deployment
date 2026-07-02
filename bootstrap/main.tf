###############################################################################
# Bootstrap layer — the "landing zone" for the Databricks-on-GCP workload.
#
# Provisions, ONCE per project, the things the workload deploy assumes already
# exist: the automation service account, its IAM floor, and the GitHub WIF
# pool/provider. Run by a PROJECT OWNER (high privilege), separately from and
# rarely compared to the workload deploy.
#
# WHY separate: the workload CI runs AS the automation SA. An identity must never
# Terraform-manage its own permissions (it self-locks on destroy and hits a
# chicken-and-egg on create). So the floor lives here, owned by a different
# (owner) identity, in its own state.
#
# This is NOT applied to projects whose SA/WIF were created out-of-band (e.g. the
# current dev project). It is for NEW projects — see bootstrap/README.md.
#
# Usage (as owner):
#   cd bootstrap
#   terraform init -backend-config="bucket=<state-bucket>" -backend-config="prefix=bootstrap"
#   terraform apply -var-file=bootstrap.tfvars
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  # Separate state from the workload (own prefix). The state bucket is created by
  # the one-time pre-step in README.md (chicken-and-egg: TF can't hold its own
  # backend's bucket).
  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_project" "this" {
  project_id = var.project_id
}

# APIs the bootstrap layer itself needs (IAM, WIF/STS, project IAM).
resource "google_project_service" "bootstrap_apis" {
  for_each = toset([
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

###############################################################################
# Automation service account
###############################################################################

resource "google_service_account" "automation" {
  account_id   = var.automation_sa_account_id
  display_name = "Databricks automation SA"
  description  = "Runs the Databricks-on-GCP workload Terraform (CI via WIF + local via impersonation). Databricks account admin."
  project      = var.project_id

  depends_on = [google_project_service.bootstrap_apis]
}

locals {
  # Project roles the automation SA needs to run the ENTIRE workload deploy.
  # (On a shared VM/Cloud-Run SA some of these already exist; here we grant the
  #  Databricks-workload set explicitly for a clean, dedicated SA.)
  automation_sa_roles = [
    "roles/iam.roleAdmin",                   # Databricks creates custom roles as this SA
    "roles/resourcemanager.projectIamAdmin", # bind managed SAs (project setIamPolicy)
    "roles/iam.serviceAccountAdmin",         # create/delete the databricks-* SAs
    "roles/iam.serviceAccountUser",          # act as SAs
    "roles/storage.admin",                   # Terraform state bucket + DBFS bucket lifecycle
    "roles/compute.admin",                   # VPC/subnet/router/NAT/firewalls
    "roles/container.admin",                 # GKE (Databricks-managed cluster)
    "roles/serviceusage.serviceUsageAdmin",  # enable workload APIs
  ]
}

resource "google_project_iam_member" "automation_sa_roles" {
  for_each = toset(local.automation_sa_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.automation.email}"
}

# Self-impersonation: in CI the SA mints its own Google OIDC token for the
# Databricks provider (DATABRICKS_GOOGLE_SERVICE_ACCOUNT).
resource "google_service_account_iam_member" "self_token_creator" {
  service_account_id = google_service_account.automation.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.automation.email}"
}

# Optional: let a human admin impersonate the SA for LOCAL terraform runs.
resource "google_service_account_iam_member" "admin_token_creator" {
  count = var.local_admin_user == "" ? 0 : 1

  service_account_id = google_service_account.automation.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "user:${var.local_admin_user}"
}
