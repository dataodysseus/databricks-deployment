###############################################################################
# GCP IAM Module
# Creates service accounts and grants roles required by Databricks on GCP
###############################################################################

locals {
  # Databricks-required roles for GKE node service account
  gke_node_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/storage.objectAdmin",
    "roles/artifactregistry.reader",
  ]

  # Databricks-required roles for storage service account
  storage_roles = [
    "roles/storage.objectAdmin",
    "roles/storage.objectViewer",
  ]
}

###############################################################################
# GKE Node Service Account
###############################################################################

resource "google_service_account" "gke_node" {
  account_id   = "databricks-gke-node-${var.environment}"
  display_name = "Databricks GKE Node SA (${var.environment})"
  project      = var.project_id
  description  = "Service account for Databricks GKE cluster nodes"
}

resource "google_project_iam_member" "gke_node_roles" {
  for_each = toset(local.gke_node_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.gke_node.email}"
}

###############################################################################
# Storage Service Account (for DBFS/Unity Catalog root storage)
###############################################################################

resource "google_service_account" "storage" {
  account_id   = "databricks-storage-${var.environment}"
  display_name = "Databricks Storage SA (${var.environment})"
  project      = var.project_id
  description  = "Service account for Databricks DBFS and Unity Catalog storage"
}

resource "google_project_iam_member" "storage_roles" {
  for_each = toset(local.storage_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.storage.email}"
}

###############################################################################
# Allow Databricks control plane to impersonate the storage SA via Workload Identity
###############################################################################

resource "google_service_account_iam_binding" "storage_workload_identity" {
  service_account_id = google_service_account.storage.name
  role               = "roles/iam.workloadIdentityUser"

  members = [
    # Databricks uses this principal to impersonate the storage SA
    "serviceAccount:${var.project_id}.svc.id.goog[databricks/databricks]",
  ]
}

###############################################################################
# GCS bucket for DBFS root storage
###############################################################################

resource "google_storage_bucket" "dbfs_root" {
  name          = "databricks-dbfs-${var.project_id}-${var.environment}"
  project       = var.project_id
  location      = "US"
  force_destroy = var.environment != "prod" # Safety guard for prod

  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  labels = {
    environment = var.environment
    managed_by  = "terraform"
    purpose     = "databricks-dbfs"
  }
}

resource "google_storage_bucket_iam_binding" "dbfs_storage_admin" {
  bucket = google_storage_bucket.dbfs_root.name
  role   = "roles/storage.objectAdmin"
  members = [
    "serviceAccount:${google_service_account.storage.email}",
  ]
}

###############################################################################
# Enable required GCP APIs
###############################################################################

locals {
  required_apis = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "storage.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "networkmanagement.googleapis.com",
    "servicenetworking.googleapis.com",
    "iamcredentials.googleapis.com",
  ]
}

resource "google_project_service" "required_apis" {
  for_each = toset(local.required_apis)

  project                    = var.project_id
  service                    = each.value
  disable_on_destroy         = false
  disable_dependent_services = false
}

###############################################################################
# Automation service account bootstrap grants
#
# Codifies the former manual §6 gcloud steps from DEPLOYMENT_GUIDE.md so a clean
# deploy needs zero manual IAM commands.
#
# NOTE (bootstrap floor): these resources set IAM policy on the project and on the
# automation SA. The identity running the FIRST `terraform apply` must therefore
# already hold roles/resourcemanager.projectIamAdmin (or Owner) and
# roles/iam.serviceAccountAdmin on the SA. A Project Owner satisfies both. This is
# the irreducible floor — you cannot grant IAM without permission to set IAM policy.
###############################################################################

locals {
  # §6b — project-level roles the automation SA needs because Databricks acts AS it
  # to create custom roles and bind its managed service accounts during workspace
  # creation. Missing these produces "Insufficient permissions … iam.roles.create,
  # … resourcemanager.projects.setIamPolicy, … iam.serviceAccounts.setIamPolicy".
  automation_sa_project_roles = [
    "roles/iam.roleAdmin",                   # iam.roles.create/update/delete/get
    "roles/resourcemanager.projectIamAdmin", # resourcemanager.projects.get/setIamPolicy
    "roles/iam.serviceAccountAdmin",         # iam.serviceAccounts.get/setIamPolicy
  ]
}

# §6b — grant the automation SA its project-level roles
resource "google_project_iam_member" "automation_sa_roles" {
  for_each = toset(local.automation_sa_project_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${var.automation_sa_email}"
}

# §6a — let human/CI identities impersonate the automation SA to mint the identity
# token the Databricks provider needs. Without this: "cannot configure default
# credentials".
resource "google_service_account_iam_member" "automation_sa_token_creator" {
  for_each = toset(var.terraform_admin_principals)

  service_account_id = "projects/${var.project_id}/serviceAccounts/${var.automation_sa_email}"
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = each.value
}
