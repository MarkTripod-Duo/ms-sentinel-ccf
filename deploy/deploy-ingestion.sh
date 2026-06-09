#!/usr/bin/env bash
#
# Stage 2 — create the ingestion resources for the Duo CCF connector:
#   * a Data Collection Endpoint (DCE)
#   * the three custom DuoSecurity*_CL tables
#   * the Data Collection Rule (DCR) with 3 streams + transforms
# and print the two values Stage 3 needs: the DCE logs-ingestion URL and the DCR immutable id.
#
# Prereqs: az CLI (logged in). Run Stage 1 (deploy-proxy.sh) and create the Sentinel workspace first.
#
# Usage:
#   ./deploy-ingestion.sh \
#       --resource-group rg-sentinel-duo-test \
#       --workspace      law-sentinel-duo-test \
#       [--location      eastus] \
#       [--dce-name      duo-ccf-dce] \
#       [--dcr-name      duo-ccf-dcr]
#
set -euo pipefail

LOCATION="eastus"
DCE_NAME="duo-ccf-dce"
DCR_NAME="duo-ccf-dcr"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group) RG="$2"; shift 2 ;;
    --workspace)      WS="$2"; shift 2 ;;
    --location)       LOCATION="$2"; shift 2 ;;
    --dce-name)       DCE_NAME="$2"; shift 2 ;;
    --dcr-name)       DCR_NAME="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

: "${RG:?--resource-group is required}"
: "${WS:?--workspace is required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> [1/3] Ensuring Data Collection Endpoint '$DCE_NAME' in '$LOCATION'..."
DCE_ID="$(az monitor data-collection endpoint show -g "$RG" -n "$DCE_NAME" --query id -o tsv 2>/dev/null || true)"
if [[ -z "$DCE_ID" ]]; then
  az monitor data-collection endpoint create \
    -g "$RG" -n "$DCE_NAME" -l "$LOCATION" --public-network-access Enabled -o none
  DCE_ID="$(az monitor data-collection endpoint show -g "$RG" -n "$DCE_NAME" --query id -o tsv)"
  echo "    created."
else
  echo "    already exists, reusing."
fi

echo "==> [2/3] Resolving workspace resource id..."
WS_ID="$(az monitor log-analytics workspace show -g "$RG" -n "$WS" --query id -o tsv)"

echo "==> [3/3] Deploying tables + DCR..."
az deployment group create \
  -g "$RG" -n duo-ccf-ingestion \
  --template-file "$SCRIPT_DIR/ingestion-template.json" \
  --parameters workspaceName="$WS" workspaceResourceId="$WS_ID" \
               dataCollectionEndpointId="$DCE_ID" dcrName="$DCR_NAME" location="$LOCATION" \
  -o none

DCR_IMMUTABLE_ID="$(az deployment group show -g "$RG" -n duo-ccf-ingestion --query properties.outputs.dcrImmutableId.value -o tsv)"
DCE_URL="$(az deployment group show -g "$RG" -n duo-ccf-ingestion --query properties.outputs.dceLogsIngestionEndpoint.value -o tsv)"

cat <<EOF

============================================================
 Ingestion resources ready. Use these in the connector pollers:
------------------------------------------------------------
 {{dataCollectionEndpoint}}        : ${DCE_URL}
 {{dataCollectionRuleImmutableId}} : ${DCR_IMMUTABLE_ID}
------------------------------------------------------------
 Tables created:  DuoSecurityAuthentication_CL, DuoSecurityActivity_CL, DuoSecurityTelephony_CL
 DCR streams:     Custom-DuoSecurityAuthentication_CL / ...Activity_CL / ...Telephony_CL
============================================================
EOF
