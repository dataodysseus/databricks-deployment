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

# NOTE: The automation SA's own bootstrap IAM (roleAdmin, projectIamAdmin,
# serviceAccountAdmin) and the tokenCreator impersonation grants are intentionally
# NOT managed here. Because the CI runner IS the automation SA, having Terraform
# manage the SA's own permissions causes a self-lockout on destroy (it removes its
# projectIamAdmin, then can't delete the last binding) and a chicken-and-egg on a
# fresh apply. These grants are pre-provisioned out-of-band — see scripts/bootstrap.sh
# and DEPLOYMENT_GUIDE.md §6.
