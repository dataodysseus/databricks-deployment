#!/usr/bin/env bash
###############################################################################
# teardown.sh - Destroy the Databricks-on-GCP stack for an environment.
#
# Handles the Databricks "orphaned firewall" quirk: Databricks creates firewall
# rule(s) (prefixed `db-`) inside your customer-managed VPC that are NOT tracked
# by Terraform. They block deletion of the VPC, so `terraform destroy` fails on
# the last resource with:
#   "The network resource ... is already being used by .../firewalls/db-..."
# This script detects that, deletes the leftover rules, and retries the destroy.
#
# Usage:
#   ./scripts/teardown.sh [env]      # env defaults to "dev"
#   ./scripts/teardown.sh dev
###############################################################################

set -euo pipefail

ENV="${1:-dev}"
VAR_FILE="environments/${ENV}/${ENV}.tfvars"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# Run from the project root (parent of scripts/) regardless of where invoked.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

[[ -f "$VAR_FILE" ]] || err "var-file not found: $VAR_FILE"
command -v terraform >/dev/null || err "terraform not found"
command -v gcloud    >/dev/null || err "gcloud not found"

# ── Derive everything from the tfvars (single source of truth) ────────────────
tfvar() { grep -E "^${1}[[:space:]]*=" "$VAR_FILE" | head -1 | cut -d'"' -f2; }

GCP_PROJECT_ID="$(tfvar gcp_project_id)"
NETWORK_NAME="$(tfvar network_name)"; NETWORK_NAME="${NETWORK_NAME:-databricks-vpc}"
VPC="${NETWORK_NAME}-${ENV}"
SA="$(tfvar automation_service_account_email)"
ACCOUNT_ID="$(tfvar databricks_account_id)"

# ── Databricks provider auth (google-id impersonation of the automation SA) ───
export DATABRICKS_HOST="https://accounts.gcp.databricks.com"
export DATABRICKS_ACCOUNT_ID="$ACCOUNT_ID"
export DATABRICKS_GOOGLE_SERVICE_ACCOUNT="$SA"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Teardown: env=${ENV}  project=${GCP_PROJECT_ID}  vpc=${VPC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Delete Databricks-created (untracked) firewall rules attached to the VPC.
# At teardown time the Terraform-managed rules are already gone, so anything
# left on this network is an orphan and safe to remove.
cleanup_orphan_firewalls() {
  local rules
  rules="$(gcloud compute firewall-rules list \
            --project="$GCP_PROJECT_ID" \
            --filter="network~${VPC}" \
            --format='value(name)' 2>/dev/null || true)"
  if [[ -z "$rules" ]]; then
    log "No leftover firewall rules on ${VPC}."
    return 0
  fi
  warn "Deleting Databricks-created firewall rules on ${VPC} (not in TF state):"
  while read -r r; do
    [[ -z "$r" ]] && continue
    gcloud compute firewall-rules delete "$r" --project="$GCP_PROJECT_ID" --quiet \
      && log "  deleted $r"
  done <<< "$rules"
}

terraform init -input=false >/dev/null

attempt=1; max=3
while (( attempt <= max )); do
  echo ""
  echo "── terraform destroy (attempt ${attempt}/${max}) ──"
  if terraform destroy -var-file="$VAR_FILE" -auto-approve; then
    break
  fi
  warn "Destroy failed — likely the VPC is still in use by a Databricks firewall."
  cleanup_orphan_firewalls
  attempt=$((attempt + 1))
done

(( attempt > max )) && err "Destroy still failing after ${max} attempts. Inspect: terraform state list; gcloud compute firewall-rules list --filter=network~${VPC}"

# ── Verify ────────────────────────────────────────────────────────────────────
remaining="$(terraform state list 2>/dev/null | wc -l | tr -d ' ')"
echo ""
if [[ "$remaining" == "0" ]]; then
  log "State is empty — full teardown confirmed."
else
  warn "${remaining} resource(s) still in state:"
  terraform state list
  exit 1
fi

echo ""
echo "Note: manual IAM grants (roleAdmin/projectIamAdmin/serviceAccountAdmin on"
echo "the automation SA) and the enabled APIs are intentionally left in place."
