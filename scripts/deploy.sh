#!/usr/bin/env bash
###############################################################################
# deploy.sh - Deploy (or update) the Databricks-on-GCP stack for an environment.
#
# Sets the Databricks provider auth env vars from the tfvars, then runs
# init + apply. Prints the workspace URL on success.
#
# Prereqs (one time): ./scripts/bootstrap.sh, and the IAM grants in §6 of
# DEPLOYMENT_GUIDE.md (you must be able to impersonate the automation SA).
#
# Usage:
#   ./scripts/deploy.sh [env]        # env defaults to "dev"
###############################################################################

set -euo pipefail

ENV="${1:-dev}"
VAR_FILE="environments/${ENV}/${ENV}.tfvars"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
log() { echo -e "${GREEN}[✓]${NC} $1"; }
err() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

[[ -f "$VAR_FILE" ]] || err "var-file not found: $VAR_FILE"
command -v terraform >/dev/null || err "terraform not found"

tfvar() { grep -E "^${1}[[:space:]]*=" "$VAR_FILE" | head -1 | cut -d'"' -f2; }

export DATABRICKS_HOST="https://accounts.gcp.databricks.com"
export DATABRICKS_ACCOUNT_ID="$(tfvar databricks_account_id)"
export DATABRICKS_GOOGLE_SERVICE_ACCOUNT="$(tfvar automation_service_account_email)"

GCP_PROJECT_ID="$(tfvar gcp_project_id)"
TFSTATE_BUCKET="databricks-tfstate-${GCP_PROJECT_ID}"

echo ""
echo "── Deploying env=${ENV} (account ${DATABRICKS_ACCOUNT_ID}) ──"
echo ""

# Init against the GCS remote-state backend, per-environment prefix.
terraform init -input=false -reconfigure \
  -backend-config="bucket=${TFSTATE_BUCKET}" \
  -backend-config="prefix=databricks/${ENV}" >/dev/null
terraform apply -var-file="$VAR_FILE" -auto-approve

echo ""
log "Deploy complete. Workspace URL:"
terraform output workspace_url
