#!/usr/bin/env bash
#
# End-to-end test of the native-auth Duo CCF deployment, with per-stage PASS/FAIL:
#   0. resource group + workspace + Sentinel onboarding
#   1. ingestion resources (DCE + 3 tables + DCR)            -> deploy-ingestion.sh
#   2. the three connectors with the built-in CiscoDuo auth  -> deploy-connector.sh (active pollers, no proxy)
#   3. build + ARM-validate the self-contained package        -> build-package.sh + az deployment group validate
#   4. verify (tables populate, pagination, NO Function App / Key Vault in the resource group)
#
# There is no signing proxy: the pollers call the Duo Admin API directly using Microsoft's built-in
# CiscoDuo auth type. The Duo credentials are passed to the scripted connector deploy so the pollers are
# active immediately (the Content Hub package instead resolves them at Connect time).
#
# Prereqs: az CLI (logged in), python3 + pyyaml, curl.
#
# Usage:
#   ./test-package-deployment.sh --duo-host https://api-XXXX.duosecurity.com --ikey DI... --skey '<skey>' \
#       [--resource-group rg-sentinel-duo-test] [--workspace law-sentinel-duo-test] [--location eastus] \
#       [--skip-env] [--wait-for-data <minutes>] [--dry-run]
#
set -uo pipefail

RG="rg-sentinel-duo-test"; WS="law-sentinel-duo-test"; LOC="eastus"
DUO_HOST=""; IKEY=""; SKEY=""
SKIP_ENV=false; WAIT_DATA=0; DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --duo-host) DUO_HOST="$2"; shift 2 ;;
    --ikey) IKEY="$2"; shift 2 ;;
    --skey) SKEY="$2"; shift 2 ;;
    --resource-group) RG="$2"; shift 2 ;;
    --workspace) WS="$2"; shift 2 ;;
    --location) LOC="$2"; shift 2 ;;
    --skip-env) SKIP_ENV=true; shift ;;
    --wait-for-data) WAIT_DATA="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MT="$ROOT/solution/Package/mainTemplate.json"
FAILS=0
hr()   { printf '\n=== %s ===\n' "$1"; }
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAILS=$((FAILS+1)); }
info() { echo "  ..    $*"; }

if $DRY_RUN; then
  cat <<EOF
DRY-RUN plan (resource group '$RG', workspace '$WS' in $LOC):
  Stage 0  az group create / workspace create / Sentinel onboardingStates PUT      $($SKIP_ENV && echo '(skipped)')
  Stage 1  deploy/deploy-ingestion.sh        -> DCE + 3 tables + DCR
  Stage 2  deploy/deploy-connector.sh         -> 3 connectors, built-in CiscoDuo auth (active pollers, no proxy)
  Stage 3  deploy/build-package.sh + az deployment group validate (workspace + workspace-location only)
  Stage 4  verify tables populate; pagination; NO Function App / Key Vault present
Run without --dry-run to execute. Nothing was done.
EOF
  exit 0
fi

: "${DUO_HOST:?--duo-host is required}"
: "${IKEY:?--ikey is required}"
: "${SKEY:?--skey is required}"
SUB="$(az account show --query id -o tsv 2>/dev/null)" || { echo "Not logged in to az." >&2; exit 1; }

# --- Stage 0: environment ---
hr "Stage 0 — environment"
if $SKIP_ENV; then info "skipped (--skip-env)"; else
  az group create -n "$RG" -l "$LOC" -o none && pass "resource group $RG" || fail "resource group create"
  az monitor log-analytics workspace create -g "$RG" -n "$WS" -l "$LOC" -o none && pass "workspace $WS" || fail "workspace create"
  az rest --method put -o none \
    --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.OperationalInsights/workspaces/$WS/providers/Microsoft.SecurityInsights/onboardingStates/default?api-version=2023-11-01" \
    --body '{"properties":{}}' && pass "Sentinel onboarded" || fail "Sentinel onboarding"
fi

# --- Stage 1: ingestion ---
hr "Stage 1 — ingestion (DCE + tables + DCR)"
if "$SCRIPT_DIR/deploy-ingestion.sh" --resource-group "$RG" --workspace "$WS" --location "$LOC" >/tmp/duo-ingestion.log 2>&1; then
  pass "ingestion deployed"
else
  fail "deploy-ingestion.sh"; tail -8 /tmp/duo-ingestion.log; echo "  -> aborting."; exit 1
fi
DCE_URL="$(az deployment group show -g "$RG" -n duo-ccf-ingestion --query properties.outputs.dceLogsIngestionEndpoint.value -o tsv 2>/dev/null)"
DCR_ID="$(az deployment group show -g "$RG" -n duo-ccf-ingestion --query properties.outputs.dcrImmutableId.value -o tsv 2>/dev/null)"
[ -n "$DCE_URL" ] && [ -n "$DCR_ID" ] && pass "captured DCE URL + DCR immutable id" || { fail "DCE/DCR outputs missing"; exit 1; }

# --- Stage 2: connectors (native CiscoDuo auth) ---
hr "Stage 2 — connectors (built-in CiscoDuo auth, no proxy)"
if "$SCRIPT_DIR/deploy-connector.sh" --resource-group "$RG" --workspace "$WS" \
     --duo-host "$DUO_HOST" --ikey "$IKEY" --skey "$SKEY" --dce "$DCE_URL" --dcr-immutable-id "$DCR_ID" >/tmp/duo-connector.log 2>&1; then
  pass "3 connectors deployed (active pollers)"
else
  fail "deploy-connector.sh"; tail -12 /tmp/duo-connector.log; echo "  -> aborting."; exit 1
fi
BASE="https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.OperationalInsights/workspaces/$WS/providers/Microsoft.SecurityInsights"
POLLERS="$(az rest --method get --url "$BASE/dataConnectors?api-version=2023-02-01-preview" --query "length(value[?kind=='RestApiPoller'])" -o tsv 2>/dev/null || echo 0)"
[ "${POLLERS:-0}" -ge 3 ] 2>/dev/null && pass "$POLLERS RestApiPoller connections, CiscoDuo auth" || fail "pollers: ${POLLERS:-0} (expected >=3)"

# --- Stage 3: build + validate the package ---
hr "Stage 3 — build + ARM-validate the package"
if "$SCRIPT_DIR/build-package.sh" >/tmp/duo-buildpkg.log 2>&1; then
  pass "package built"
else
  fail "build-package.sh"; tail -5 /tmp/duo-buildpkg.log; exit 1
fi
grep -q '"proxyBaseUrl"\|"functionKey"' "$MT" && fail "package still references proxy params" || pass "package has no proxy parameters"
if az deployment group validate -g "$RG" --template-file "$MT" \
     --parameters workspace="$WS" workspace-location="$LOC" \
     --query properties.provisioningState -o tsv 2>/tmp/duo-val.log | grep -q Succeeded; then
  pass "ARM validate"
else
  fail "ARM validate"; tail -8 /tmp/duo-val.log
fi

# --- Stage 4: verify ---
hr "Stage 4 — verify"
# proxy-free: no Function App / Key Vault anywhere in the resource group
LEFTOVER="$(az resource list -g "$RG" --query "length([?type=='Microsoft.Web/sites' || type=='Microsoft.KeyVault/vaults'])" -o tsv 2>/dev/null || echo '?')"
[ "$LEFTOVER" = "0" ] && pass "no Function App / Key Vault in resource group (proxy-free)" || fail "found $LEFTOVER Function App/Key Vault resources (expected 0)"
WS_GUID="$(az monitor log-analytics workspace show -g "$RG" -n "$WS" --query customerId -o tsv 2>/dev/null)"
get_count() { az monitor log-analytics query --workspace "$WS_GUID" --analytics-query "DuoSecurityAuthentication_CL | count" --query "[0].Count" -o tsv 2>/dev/null || echo 0; }
if [ "${WAIT_DATA:-0}" -gt 0 ]; then
  info "waiting up to ${WAIT_DATA}m for first events (pollers run on a schedule)..."
  C=0; for _ in $(seq 1 "$WAIT_DATA"); do C="$(get_count)"; [ "${C:-0}" -gt 0 ] 2>/dev/null && break; sleep 60; done
  [ "${C:-0}" -gt 0 ] 2>/dev/null && pass "authentication data flowing ($C events) — native CiscoDuo auth works" || fail "no data after ${WAIT_DATA}m"
  info "to confirm the next_offset cursor, generate >1000 events in a window and re-check all three tables"
else
  info "auth events so far: $(get_count) (populate ~5-10 min after Connect; re-check or use --wait-for-data 15)"
  info "next_offset pagination: generate >1000 events in one window and confirm all ingest"
fi

# --- Summary ---
hr "Summary"
if [ "$FAILS" -eq 0 ]; then
  echo "  ALL STAGES PASSED. Native CiscoDuo auth deployed and active — no signing proxy."
else
  echo "  $FAILS check(s) FAILED — see above."
fi
exit $(( FAILS > 0 ? 1 : 0 ))
