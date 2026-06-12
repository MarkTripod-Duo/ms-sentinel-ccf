#!/usr/bin/env bash
#
# Tear down the Duo CCF *test* environment for a clean from-scratch redeploy.
#
# DESTRUCTIVE. Permanently deletes the workspace (no soft-delete recovery, so a re-deploy with the same
# name starts clean) and deletes the resource group (DCE, DCRs, tables, connectors, content). The native
# CiscoDuo connector has no signing proxy, so there is no Function App / Key Vault to clean up.
#
# Usage:
#   ./reset-test-env.sh [--resource-group rg-sentinel-duo-test] [--workspace law-sentinel-duo-test]
#                       [--yes] [--dry-run]
#     --yes       skip the typed confirmation (for non-interactive use)
#     --dry-run   inventory and print what WOULD be deleted; delete nothing
#
set -euo pipefail

RG="rg-sentinel-duo-test"
WS="law-sentinel-duo-test"
ASSUME_YES=false
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group) RG="$2"; shift 2 ;;
    --workspace)      WS="$2"; shift 2 ;;
    --yes)            ASSUME_YES=true; shift ;;
    --dry-run)        DRY_RUN=true; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

run() {  # execute, or echo in dry-run mode
  if $DRY_RUN; then echo "  DRY-RUN would run:  $*"; else "$@"; fi
}

echo "Subscription: $(az account show --query name -o tsv 2>/dev/null) ($(az account show --query id -o tsv 2>/dev/null))"
echo "Target:       resource group '$RG', workspace '$WS'"$([ "$DRY_RUN" = true ] && echo "   [DRY-RUN]")
echo

RG_EXISTS=$(az group exists -n "$RG" 2>/dev/null || echo false)
LOC=""
if [ "$RG_EXISTS" = "true" ]; then
  echo "== Resources in $RG =="
  az resource list -g "$RG" --query "sort_by([].{name:name, type:type}, &type)" -o table 2>/dev/null
  echo
  LOC=$(az group show -n "$RG" --query location -o tsv 2>/dev/null)
else
  echo "Resource group '$RG' not found — nothing to delete."
  exit 0
fi

echo "Will delete:"
echo "  - workspace '$WS' (PERMANENT, no recovery) + its tables/functions/rules/Sentinel"
echo "  - resource group '$RG' (DCE, DCRs, connectors, content)"
echo

# --- Confirmation ---
if ! $ASSUME_YES && ! $DRY_RUN; then
  read -r -p "Type the resource group name ('$RG') to confirm permanent deletion: " CONFIRM
  [ "$CONFIRM" = "$RG" ] || { echo "Confirmation did not match — aborting. Nothing deleted."; exit 1; }
fi

# --- 1. Permanently delete the workspace (bypasses 14-day soft-delete recovery) ---
if az monitor log-analytics workspace show -g "$RG" -n "$WS" -o none 2>/dev/null; then
  echo "==> Permanently deleting workspace '$WS'..."
  run az monitor log-analytics workspace delete -g "$RG" -n "$WS" --force true --yes
fi

# --- 2. Delete the resource group ---
echo "==> Deleting resource group '$RG' (this takes a few minutes)..."
run az group delete -n "$RG" --yes

echo
if $DRY_RUN; then
  echo "DRY-RUN complete — nothing was deleted."
  exit 0
fi

echo "== Verifying =="
echo "  group exists '$RG': $(az group exists -n "$RG" 2>/dev/null)"

cat <<EOF

============================================================
 Test environment reset. Re-deploy from scratch:

   # Stage 0 — resource group, workspace, Sentinel onboarding
   az group create -n $RG -l ${LOC:-eastus}
   az monitor log-analytics workspace create -g $RG -n $WS -l ${LOC:-eastus}
   SUB=\$(az account show --query id -o tsv)
   az rest --method put --url "https://management.azure.com/subscriptions/\$SUB/resourceGroups/$RG/providers/Microsoft.OperationalInsights/workspaces/$WS/providers/Microsoft.SecurityInsights/onboardingStates/default?api-version=2023-11-01" --body '{"properties":{}}'

   # Stages 1-2 (no proxy — native CiscoDuo auth)
   deploy/deploy-ingestion.sh --resource-group $RG --workspace $WS
   deploy/deploy-connector.sh --resource-group $RG --workspace $WS --duo-host https://api-XXXX.duosecurity.com --ikey <ikey> --skey <skey> --dce <dce-url> --dcr-immutable-id <dcr-id>
   # or one-shot:  deploy/test-package-deployment.sh --duo-host https://api-XXXX.duosecurity.com --ikey <ikey> --skey <skey>
   # or package:   deploy/build-package.sh  then deploy solution/Package/mainTemplate.json and Connect on each connector page
============================================================
EOF
