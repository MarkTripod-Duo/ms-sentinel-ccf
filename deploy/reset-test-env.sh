#!/usr/bin/env bash
#
# Tear down the Duo CCF *test* environment for a clean from-scratch redeploy.
#
# DESTRUCTIVE. Permanently deletes the workspace (no soft-delete recovery, so a re-deploy with the same
# name starts clean), deletes the resource group, purges the Key Vault (its name is derived from the RG +
# app name, so it must be purged before redeploy), and removes the App Insights managed RG.
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

# --- Discover dependent resources BEFORE deletion (names needed for purge/cleanup) ---
KVS=""; LOC=""; APP=""; MANAGED_RG=""
if [ "$RG_EXISTS" = "true" ]; then
  echo "== Resources in $RG =="
  az resource list -g "$RG" --query "sort_by([].{name:name, type:type}, &type)" -o table 2>/dev/null
  echo
  LOC=$(az group show -n "$RG" --query location -o tsv 2>/dev/null)
  KVS=$(az keyvault list -g "$RG" --query "[].name" -o tsv 2>/dev/null || true)
  APP=$(az functionapp list -g "$RG" --query "[0].name" -o tsv 2>/dev/null || true)
  if [ -n "$APP" ]; then
    MANAGED_RG=$(az group list --query "[?starts_with(name, 'ai_${APP}-ai_')].name" -o tsv 2>/dev/null || true)
  fi
else
  echo "Resource group '$RG' not found — checking for leftover soft-deleted Key Vaults to purge."
  KVS=$(az keyvault list-deleted --query "[?starts_with(name,'duo-kv-')].name" -o tsv 2>/dev/null || true)
  LOC=$(az keyvault list-deleted --query "[?starts_with(name,'duo-kv-')].properties.location | [0]" -o tsv 2>/dev/null || true)
fi

echo "Will delete:"
[ "$RG_EXISTS" = "true" ] && echo "  - workspace '$WS' (PERMANENT, no recovery) + its tables/functions/rules/Sentinel"
[ "$RG_EXISTS" = "true" ] && echo "  - resource group '$RG' (proxy, DCE, DCR, storage, plan, App Insights, Key Vault)"
[ -n "$KVS" ]            && echo "  - purge Key Vault(s): $(echo $KVS | tr '\n' ' ')"
[ -n "$MANAGED_RG" ]     && echo "  - App Insights managed RG: $(echo $MANAGED_RG | tr '\n' ' ')"
echo

if [ "$RG_EXISTS" != "true" ] && [ -z "$KVS" ]; then
  echo "Nothing to do — already clean."; exit 0
fi

# --- Confirmation ---
if ! $ASSUME_YES && ! $DRY_RUN; then
  read -r -p "Type the resource group name ('$RG') to confirm permanent deletion: " CONFIRM
  [ "$CONFIRM" = "$RG" ] || { echo "Confirmation did not match — aborting. Nothing deleted."; exit 1; }
fi

# --- 1. Permanently delete the workspace (bypasses 14-day soft-delete recovery) ---
if [ "$RG_EXISTS" = "true" ] && az monitor log-analytics workspace show -g "$RG" -n "$WS" -o none 2>/dev/null; then
  echo "==> Permanently deleting workspace '$WS'..."
  run az monitor log-analytics workspace delete -g "$RG" -n "$WS" --force true --yes
fi

# --- 2. Delete the resource group ---
if [ "$RG_EXISTS" = "true" ]; then
  echo "==> Deleting resource group '$RG' (this takes a few minutes)..."
  run az group delete -n "$RG" --yes
fi

# --- 3. Purge soft-deleted Key Vault(s) ---
for KV in $KVS; do
  echo "==> Purging Key Vault '$KV'..."
  if $DRY_RUN; then
    echo "  DRY-RUN would run:  az keyvault purge --name $KV ${LOC:+--location $LOC}"
  else
    az keyvault purge --name "$KV" ${LOC:+--location "$LOC"} 2>/dev/null || echo "   (already purged or purge-protected)"
  fi
done

# --- 4. App Insights managed RG (usually auto-removed with step 2) ---
for M in $MANAGED_RG; do
  if [ "$(az group exists -n "$M" 2>/dev/null || echo false)" = "true" ]; then
    echo "==> Removing App Insights managed RG '$M'..."
    run az group delete -n "$M" --yes --no-wait
  fi
done

echo
if $DRY_RUN; then
  echo "DRY-RUN complete — nothing was deleted."
  exit 0
fi

echo "== Verifying =="
echo "  group exists '$RG': $(az group exists -n "$RG" 2>/dev/null)"
for KV in $KVS; do
  echo "  soft-deleted KV '$KV': $(az keyvault list-deleted --query "[?name=='$KV'].name" -o tsv 2>/dev/null || echo none)"
done

cat <<EOF

============================================================
 Test environment reset. Re-deploy from scratch:

   # Stage 0 — resource group, workspace, Sentinel onboarding
   az group create -n $RG -l ${LOC:-eastus}
   az monitor log-analytics workspace create -g $RG -n $WS -l ${LOC:-eastus}
   SUB=\$(az account show --query id -o tsv)
   az rest --method put --url "https://management.azure.com/subscriptions/\$SUB/resourceGroups/$RG/providers/Microsoft.OperationalInsights/workspaces/$WS/providers/Microsoft.SecurityInsights/onboardingStates/default?api-version=2023-11-01" --body '{"properties":{}}'

   # Stages 1-3
   deploy/deploy-proxy.sh --resource-group $RG --app-name <unique> --duo-host <api-XXXX.duosecurity.com> --duo-ikey <ikey> --duo-skey <skey>
   deploy/deploy-ingestion.sh --resource-group $RG --workspace $WS
   deploy/deploy-connector.sh --resource-group $RG --workspace $WS --proxy-url <url> --function-key <key> --dce <dce-url> --dcr-immutable-id <dcr-id>
   # or:  deploy/build-package.sh  then deploy solution/Package/mainTemplate.json
============================================================
EOF
