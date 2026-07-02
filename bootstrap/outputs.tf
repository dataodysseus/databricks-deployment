###############################################################################
# Bootstrap outputs — the values to paste into GitHub Environment secrets.
###############################################################################

output "GCP_PROJECT_ID" {
  description = "Secret: GCP_PROJECT_ID"
  value       = var.project_id
}

output "GCP_SERVICE_ACCOUNT" {
  description = "Secret: GCP_SERVICE_ACCOUNT (automation SA email)"
  value       = google_service_account.automation.email
}

output "GCP_WORKLOAD_IDENTITY_PROVIDER" {
  description = "Secret: GCP_WORKLOAD_IDENTITY_PROVIDER (full resource name)"
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "next_steps" {
  description = "Manual steps that cannot be automated via GCP APIs"
  value       = <<-EOT
    1. Add ${google_service_account.automation.email} as an ACCOUNT ADMIN in the
       Databricks account console (accounts.gcp.databricks.com) — console-only step.
    2. Create the 5 GitHub Environment secrets: the three above, plus
       DATABRICKS_ACCOUNT_ID and DATABRICKS_ADMIN_USER.
    3. Run the "Deploy Databricks Workspace" workflow (action=plan, then apply).
  EOT
}
