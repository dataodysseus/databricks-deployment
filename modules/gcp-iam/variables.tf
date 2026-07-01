###############################################################################
# GCP IAM Module - Variables
###############################################################################

variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "databricks_account_id" {
  description = "Databricks Account ID"
  type        = string
  sensitive   = true
}

variable "automation_sa_email" {
  description = <<-EOT
    Email of the pre-existing automation service account that is registered as an
    Account Admin in the Databricks account console and that Databricks impersonates
    during workspace creation. This module grants it the project-level roles it needs
    (codifies the former manual §6b gcloud steps).
  EOT
  type        = string
}

variable "terraform_admin_principals" {
  description = <<-EOT
    IAM principals (e.g. "user:you@gmail.com", "group:platform@example.com") that are
    allowed to impersonate the automation SA to mint identity tokens for the Databricks
    provider. Grants roles/iam.serviceAccountTokenCreator on the automation SA
    (codifies the former manual §6a gcloud step). Leave empty to skip.
  EOT
  type        = list(string)
  default     = []
}
