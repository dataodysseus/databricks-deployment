###############################################################################
# Workspace Access Assignment
# Assigns account users to the workspace with an entitlement so they can log in.
# Without this, a user authenticates via Google SSO but gets
# "You do not have permission to access this page in workspace ...".
###############################################################################

# Look up the account-level user by email.
data "databricks_user" "admin" {
  provider  = databricks.accounts
  user_name = var.workspace_admin_user
}

# Grant that user ADMIN on the workspace.
resource "databricks_mws_permission_assignment" "admin" {
  provider     = databricks.accounts
  workspace_id = module.databricks_workspace.workspace_id
  principal_id = data.databricks_user.admin.id
  permissions  = ["ADMIN"]
}
