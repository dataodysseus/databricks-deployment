###############################################################################
# GitHub Actions Workload Identity Federation
#
# Creates the pool + OIDC provider that lets GitHub Actions in your repo(s)
# impersonate the automation SA WITHOUT any exported key. Scoped to a GitHub
# owner (org/user) via the attribute condition — any repo under that owner can
# authenticate, matching the pattern already in use.
###############################################################################

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = var.wif_pool_id
  display_name              = "GitHub Actions Pool"
  description               = "WIF pool for GitHub Actions deployments"

  depends_on = [google_project_service.bootstrap_apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = var.wif_provider_id
  display_name                       = "GitHub OIDC Provider"

  # Only tokens from repos owned by var.github_repo_owner may use this provider.
  attribute_condition = "assertion.repository_owner == '${var.github_repo_owner}'"

  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.actor"            = "assertion.actor"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
  }

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Allow identities from this owner's repos to impersonate the automation SA.
resource "google_service_account_iam_member" "wif_impersonation" {
  service_account_id = google_service_account.automation.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.github.workload_identity_pool_id}/attribute.repository_owner/${var.github_repo_owner}"
}
