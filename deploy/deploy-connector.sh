#!/usr/bin/env bash
#
# Stage 3 — deploy the Duo CCF connector: the data connector definition (UI) and the three
# RestApiPoller connections, wired to the signing proxy and the Stage 2 DCE/DCR. Once the pollers
# are created (isActive=true), Microsoft Sentinel begins polling Duo through the proxy.
#
# Bodies are rendered from the canonical source under
# solution/Data Connectors/DuoSecurityCCF_ccp/ (no hand-copied drift).
#
# Prereqs: az CLI (logged in). Run Stage 1 (deploy-proxy.sh) and Stage 2 (deploy-ingestion.sh) first.
#
# Usage:
#   ./deploy-connector.sh \
#       --resource-group     rg-sentinel-duo-test \
#       --workspace          law-sentinel-duo-test \
#       --proxy-url          https://<app>.azurewebsites.net/api \
#       --function-key       <function-key> \
#       --dce                https://<dce>.<region>.ingest.monitor.azure.com \
#       --dcr-immutable-id   dcr-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
#
set -euo pipefail

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group)   RG="$2"; shift 2 ;;
    --workspace)        WS="$2"; shift 2 ;;
    --proxy-url)        PROXY_URL="$2"; shift 2 ;;
    --function-key)     FUNCTION_KEY="$2"; shift 2 ;;
    --dce)              DCE="$2"; shift 2 ;;
    --dcr-immutable-id) DCR_ID="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

: "${RG:?--resource-group is required}"
: "${WS:?--workspace is required}"
: "${PROXY_URL:?--proxy-url is required}"
: "${FUNCTION_KEY:?--function-key is required}"
: "${DCE:?--dce is required}"
: "${DCR_ID:?--dcr-immutable-id is required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/../solution/Data Connectors/DuoSecurityCCF_ccp" && pwd)"
OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT

SUB="$(az account show --query id -o tsv)"
BASE="https://management.azure.com/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.OperationalInsights/workspaces/${WS}/providers/Microsoft.SecurityInsights"

echo "==> [1/3] Rendering bodies from source (substituting proxy/DCE/DCR values)..."
python3 "$SCRIPT_DIR/_render_connector_bodies.py" \
  --src-dir "$SRC_DIR" --out-dir "$OUT_DIR" \
  --proxy-url "$PROXY_URL" --function-key "$FUNCTION_KEY" --dce "$DCE" --dcr-id "$DCR_ID"

echo "==> [2/3] Deploying connector definition (UI)..."
az rest --method put \
  --url "${BASE}/dataConnectorDefinitions/DuoSecurityCCF?api-version=2022-09-01-preview" \
  --body "@${OUT_DIR}/definition.json" -o none
echo "    definition DuoSecurityCCF deployed."

echo "==> [3/3] Deploying the three RestApiPoller connections..."
for f in "$OUT_DIR"/poller_*.json; do
  name="$(basename "$f" .json)"; name="${name#poller_}"
  az rest --method put \
    --url "${BASE}/dataConnectors/${name}?api-version=2022-10-01-preview" \
    --body "@${f}" -o none
  echo "    poller ${name} deployed."
done

echo
echo "==> Verifying deployed connectors:"
az rest --method get \
  --url "${BASE}/dataConnectors?api-version=2022-10-01-preview" \
  --query "value[?kind=='RestApiPoller'].{name:name, stream:properties.dcrConfig.streamName, active:properties.isActive}" -o table

cat <<EOF

============================================================
 Connector deployed. Microsoft Sentinel will begin polling Duo
 (every ~5 min) through the proxy into:
   DuoSecurityAuthentication_CL / DuoSecurityActivity_CL / DuoSecurityTelephony_CL

 Watch for data (give it a poll cycle or two):
   az monitor log-analytics query --workspace <customerId> \\
     --analytics-query "DuoSecurityAuthentication_CL | take 10"
 or in the portal: Sentinel > Logs > run  DuoSecurityAuthentication_CL | take 10
============================================================
EOF
