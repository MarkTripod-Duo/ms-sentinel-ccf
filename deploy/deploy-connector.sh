#!/usr/bin/env bash
#
# Stage 2 — deploy the three Cisco Duo CCF connectors: each connector definition (UI) plus its
# RestApiPoller connection, using Microsoft's built-in **CiscoDuo** auth type to call the Duo Admin API
# directly (HMAC signing in the polling engine — no proxy). Bodies are rendered from the per-endpoint
# source folders with literal Duo credentials so the pollers are active on deploy (scripted/test path).
# For the Content Hub package, credentials are instead entered on each connector page at Connect time.
#
# Bodies are rendered from the canonical source under solution/Data Connectors/DuoSecurity*_CCF/.
#
# Prereqs: az CLI (logged in). Create the Sentinel workspace and run deploy-ingestion.sh first.
#
# Usage:
#   ./deploy-connector.sh \
#       --resource-group   rg-sentinel-duo-test \
#       --workspace        law-sentinel-duo-test \
#       --duo-host         https://api-XXXXXXXX.duosecurity.com \
#       --ikey             DIXXXXXXXXXXXXXXXXXX \
#       --skey             <duo-secret-key> \
#       --dce              https://<dce>.<region>.ingest.monitor.azure.com \
#       --dcr-immutable-id dcr-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
#
set -euo pipefail

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group)   RG="$2"; shift 2 ;;
    --workspace)        WS="$2"; shift 2 ;;
    --duo-host)         DUO_HOST="$2"; shift 2 ;;
    --ikey)             IKEY="$2"; shift 2 ;;
    --skey)             SKEY="$2"; shift 2 ;;
    --dce)              DCE="$2"; shift 2 ;;
    --dcr-immutable-id) DCR_ID="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

: "${RG:?--resource-group is required}"
: "${WS:?--workspace is required}"
: "${DUO_HOST:?--duo-host is required}"
: "${IKEY:?--ikey is required}"
: "${SKEY:?--skey is required}"
: "${DCE:?--dce is required}"
: "${DCR_ID:?--dcr-immutable-id is required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd "$SCRIPT_DIR/../solution/Data Connectors" && pwd)"
OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT

SUB="$(az account show --query id -o tsv)"
BASE="https://management.azure.com/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.OperationalInsights/workspaces/${WS}/providers/Microsoft.SecurityInsights"

echo "==> [1/3] Rendering connector bodies from source (native CiscoDuo auth, resolved credentials)..."
python3 "$SCRIPT_DIR/_render_connector_bodies.py" \
  --src-root "$SRC_ROOT" --out-dir "$OUT_DIR" \
  --duo-host "$DUO_HOST" --ikey "$IKEY" --skey "$SKEY" --dce "$DCE" --dcr-id "$DCR_ID"

echo "==> [2/3] Deploying the three connector definitions (UI)..."
for f in "$OUT_DIR"/definition_*.json; do
  id="$(basename "$f" .json)"; id="${id#definition_}"
  az rest --method put \
    --url "${BASE}/dataConnectorDefinitions/${id}?api-version=2022-09-01-preview" \
    --body "@${f}" -o none
  echo "    definition ${id} deployed."
done

echo "==> [3/3] Deploying the three RestApiPoller connections..."
for f in "$OUT_DIR"/poller_*.json; do
  name="$(basename "$f" .json)"; name="${name#poller_}"
  az rest --method put \
    --url "${BASE}/dataConnectors/${name}?api-version=2023-02-01-preview" \
    --body "@${f}" -o none
  echo "    poller ${name} deployed."
done

echo
echo "==> Verifying deployed connectors:"
az rest --method get \
  --url "${BASE}/dataConnectors?api-version=2023-02-01-preview" \
  --query "value[?kind=='RestApiPoller'].{name:name, stream:properties.dcrConfig.streamName, active:properties.isActive}" -o table

cat <<EOF

============================================================
 Connectors deployed. Microsoft Sentinel will begin polling the Duo Admin API
 directly (every ~5 min) via the built-in CiscoDuo auth type into:
   DuoSecurityAuthentication_CL / DuoSecurityActivity_CL / DuoSecurityTelephony_CL

 Watch for data (give it a poll cycle or two):
   az monitor log-analytics query --workspace <customerId> \\
     --analytics-query "DuoSecurityAuthentication_CL | take 10"
 or in the portal: Sentinel > Logs > run  DuoSecurityAuthentication_CL | take 10
============================================================
EOF
