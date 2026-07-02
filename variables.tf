###############################################################################
# Root Variables
###############################################################################

variable "gcp_project_id" {
  description = "GCP Project ID (set in your env-specific tfvars, e.g. environments/dev/dev.tfvars)"
  type        = string
}

variable "gcp_region" {
  description = "GCP region for all resources"
  type        = string
  default     = "us-central1"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "databricks_account_id" {
  description = "Databricks Account ID (found in Databricks account console; set in your tfvars)"
  type        = string
  sensitive   = true
}

variable "workspace_name" {
  description = "Databricks workspace name"
  type        = string
  default     = "databricks-gcp-dev"
}

variable "automation_service_account_email" {
  description = "Pre-existing automation SA (Databricks Account Admin) that Databricks impersonates during workspace creation. Its bootstrap IAM floor (roleAdmin/projectIamAdmin/serviceAccountAdmin + tokenCreator) is pre-provisioned out-of-band, NOT by Terraform — see DEPLOYMENT_GUIDE.md §6. Read by scripts/CI to set DATABRICKS_GOOGLE_SERVICE_ACCOUNT. Set in your tfvars."
  type        = string
}

variable "workspace_admin_user" {
  description = "Account-level Databricks user email granted ADMIN on the created workspace (see workspace_access.tf). Set in your tfvars."
  type        = string
}

# Networking
variable "network_name" {
  description = "Name of the VPC network"
  type        = string
  default     = "databricks-vpc"
}

variable "subnet_cidr" {
  description = "CIDR for the primary subnet (nodes)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "pod_cidr" {
  description = "CIDR for GKE pod secondary range"
  type        = string
  default     = "10.1.0.0/16"
}

variable "svc_cidr" {
  description = "CIDR for GKE services secondary range"
  type        = string
  default     = "10.2.0.0/20"
}
