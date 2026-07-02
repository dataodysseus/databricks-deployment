###############################################################################
# Bootstrap layer - Variables
###############################################################################

variable "project_id" {
  description = "GCP Project ID to bootstrap"
  type        = string
}

variable "region" {
  description = "Default GCP region"
  type        = string
  default     = "us-central1"
}

variable "automation_sa_account_id" {
  description = "account_id (left part of the email) for the automation SA to create"
  type        = string
  default     = "databricks-automation"
}

variable "github_repo_owner" {
  description = "GitHub org/user that owns the deployment repo(s); WIF is scoped to this owner"
  type        = string
}

variable "wif_pool_id" {
  description = "Workload Identity Pool ID"
  type        = string
  default     = "github"
}

variable "wif_provider_id" {
  description = "Workload Identity Pool Provider ID"
  type        = string
  default     = "databricks-deployment"
}

variable "local_admin_user" {
  description = "Optional human email granted tokenCreator on the SA for LOCAL terraform runs. Empty = skip."
  type        = string
  default     = ""
}
