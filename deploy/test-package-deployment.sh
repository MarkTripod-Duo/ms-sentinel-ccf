#!/usr/bin/env bash
#
# End-to-end test of the self-contained solution-package deployment, with per-stage PASS/FAIL:
#   0. resource group + workspace + Sentinel onboarding
#   1. signing proxy (deploy-proxy.sh) + smoke test
#   2. build the package (build-package.sh)
#   3. ARM-validate + deploy solution/Package/mainTemplate.json
#   4. verify (deployment state, rule/poller counts, parser resolves, data snapshot)
#
# Prereqs: az CLI (logged in), Azure Functions Core Tools (func), python3 + pyyaml, curl.
#
# Usage:
#   ./test-package-deployment.sh --duo-host api-XXXX.duosecurity.com --duo-ikey DI... --duo-skey '<skey>' \
#       [--resource-group rg-sentinel-duo-test] [--workspace law-sentinel-duo-test] [--location eastus] \
#       [--proxy-location centralus] [--proxy-app duo-ccf-proxy-test] \
#       [--skip-env] [--skip-proxy] [--wait-for-data <minutes>] [--dry-run]
#
set -uo pipefail

RG="rg-sentinel-duo-test"; WS="law-sentinel-duo-test"; LOC="eastus"
PROXY_APP="duo-ccf-proxy-test"; PROXY_LOC=""
DUO_HOST=""; DUO_IKEY=""; DUO_SKEY=""
SKIP_ENV=false; SKIP_PROXY=false; WAIT_DATA=0; DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --duo-host) DUO_HOST="$2"; shift 2 ;;
    --duo-ikey) DUO_IKEY="$2"; shift 2 ;;
    --duo-skey) DUO_SKEY="$2"; shift 2 ;;
    --resource-group) RG="$2"; shift 2 ;;
    --workspace) WS="$2"; shift 2 ;;
    --location) LOC="$2"; shift 2 ;;
    --proxy-location) PROXY_LOC="$2"; shift 2 ;;
    --proxy-app) PROXY_APP="$2"; shift 2 ;;
    --skip-env) SKIP_ENV=true; shift ;;
    --skip-proxy) SKIP_PROXY=true; shift ;;
    --wait-for-data) WAIT_DATA="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
PROXY_LOC="${PROXY_LOC:-$LOC}"

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
DRY-RUN plan (resource group '$RG', workspace '$WS' in $LOC; proxy '$PROXY_APP' in $PROXY_LOC):
  Stage 0  az group create / workspace create / Sentinel onboardingStates PUT      $($SKIP_ENV && echo '(skipped)')
  Stage 1  deploy/deploy-proxy.sh --app-name $PROXY_APP --location $PROXY_LOC ...   $($SKIP_PROXY && echo '(skipped)')
           + curl proxy /duo/authentication smoke test (expect stat:OK)
  Stage 2  deploy/build-package.sh  ->  solution/Package/mainTemplate.json
  Stage 3  az deployment group validate + create -n duo-ccf-solution (mainTemplate.json)
  Stage 4  verify deployment Succeeded; >=11 alertRules, >=3 pollers; CiscoDuo parser resolves; data snapshot
Run without --dry-run to execute. Nothing was done.
EOF
  exit 0
fi

if ! $SKIP_PROXY; then
  : "${DUO_HOST:?--duo-host is required (or use --skip-proxy)}"
  : "${DUO_IKEY:?--duo-ikey is required}"
  : "${DUO_SKEY:?--duo-skey is required}"
fi
SUB="$(az account show --query id -o tsv 2>/dev/null)" || { echo "Not logged in to az." >&2; exit 1; }
BASE="https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.OperationalInsights/workspaces/$WS/providers/Microsoft.SecurityInsights"

# --- Stage 0: environment ---
hr "Stage 0 — environment"
if $SKIP_ENV; then info "skipped (--skip-env)"; else
  az group create -n "$RG" -l "$LOC" -o none && pass "resource group $RG" || fail "resource group create"
  az monitor log-analytics workspace create -g "$RG" -n "$WS" -l "$LOC" -o none && pass "workspace $WS" || fail "workspace create"
  az rest --method put -o none \
    --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.OperationalInsights/workspaces/$WS/providers/Microsoft.SecurityInsights/onboardingStates/default?api-version=2023-11-01" \
    --body '{"properties":{}}' && pass "Sentinel onboarded" || fail "Sentinel onboarding"
fi

# --- Stage 1: signing proxy ---
hr "Stage 1 — signing proxy"
if $SKIP_PROXY; then
  info "skipped (--skip-proxy); using existing $PROXY_APP"
else
  if "$SCRIPT_DIR/deploy-proxy.sh" --resource-group "$RG" --app-name "$PROXY_APP" \
       --duo-host "$DUO_HOST" --duo-ikey "$DUO_IKEY" --duo-skey "$DUO_SKEY" --location "$PROXY_LOC"; then
    pass "proxy deployed"
  else
    fail "proxy deploy"; echo "  -> aborting (proxy is required for the package)."; exit 1
  fi
fi
PROXY_HOST="$(az functionapp show -g "$RG" -n "$PROXY_APP" --query defaultHostName -o tsv 2>/dev/null)"
PROXY_URL="https://${PROXY_HOST}/api"
PROXY_KEY="$(az functionapp keys list -g "$RG" -n "$PROXY_APP" --query functionKeys.default -o tsv 2>/dev/null)"
[ -n "$PROXY_HOST" ] && [ -n "$PROXY_KEY" ] && pass "captured proxy URL + key" || { fail "proxy URL/key not found"; exit 1; }
NOW=$(date +%s); MIN=$(( (NOW-86400)*1000 )); MAX=$(( (NOW-120)*1000 ))
STAT="$(curl -s "$PROXY_URL/duo/authentication?mintime=$MIN&maxtime=$MAX&limit=1" -H "x-functions-key: $PROXY_KEY" \
        | python3 -c "import sys,json;print(json.load(sys.stdin).get('stat','?'))" 2>/dev/null || echo "no-response")"
[ "$STAT" = "OK" ] && pass "proxy smoke test (Duo stat:OK)" || fail "proxy smoke test (got: $STAT)"

# --- Stage 2: build package ---
hr "Stage 2 — build package"
if "$SCRIPT_DIR/build-package.sh" >/tmp/duo-buildpkg.log 2>&1; then
  pass "package built"
else
  fail "build-package.sh"; tail -5 /tmp/duo-buildpkg.log; echo "  -> aborting."; exit 1
fi
[ -f "$MT" ] && pass "mainTemplate.json present" || { fail "mainTemplate.json missing"; exit 1; }

# --- Stage 3: validate + deploy ---
hr "Stage 3 — validate + deploy package"
PARAMS=(workspace="$WS" workspace-location="$LOC" proxyBaseUrl="$PROXY_URL" functionKey="$PROXY_KEY")
if az deployment group validate -g "$RG" --template-file "$MT" --parameters "${PARAMS[@]}" \
     --query properties.provisioningState -o tsv 2>/tmp/duo-val.log | grep -q Succeeded; then
  pass "ARM validate"
else
  fail "ARM validate"; tail -5 /tmp/duo-val.log; echo "  -> aborting."; exit 1
fi
if az deployment group create -g "$RG" -n duo-ccf-solution --template-file "$MT" --parameters "${PARAMS[@]}" -o none; then
  pass "package deployed"
else
  fail "package deploy"; exit 1
fi

# --- Stage 4: verify ---
hr "Stage 4 — verify"
STATE="$(az deployment group show -g "$RG" -n duo-ccf-solution --query properties.provisioningState -o tsv 2>/dev/null)"
[ "$STATE" = "Succeeded" ] && pass "deployment state Succeeded" || fail "deployment state: $STATE"
RULES="$(az rest --method get --url "$BASE/alertRules?api-version=2023-02-01" --query "length(value[?kind=='Scheduled'])" -o tsv 2>/dev/null || echo 0)"
[ "${RULES:-0}" -ge 11 ] 2>/dev/null && pass "$RULES analytic rules" || fail "analytic rules: ${RULES:-0} (expected >=11)"
POLLERS="$(az rest --method get --url "$BASE/dataConnectors?api-version=2022-10-01-preview" --query "length(value[?kind=='RestApiPoller'])" -o tsv 2>/dev/null || echo 0)"
[ "${POLLERS:-0}" -ge 3 ] 2>/dev/null && pass "$POLLERS RestApiPoller connections" || fail "pollers: ${POLLERS:-0} (expected >=3)"
WS_GUID="$(az monitor log-analytics workspace show -g "$RG" -n "$WS" --query customerId -o tsv 2>/dev/null)"
az monitor log-analytics query --workspace "$WS_GUID" --analytics-query "CiscoDuo | limit 0" -o none 2>/dev/null \
  && pass "CiscoDuo parser resolves" || fail "CiscoDuo parser does not resolve"
get_count() { az monitor log-analytics query --workspace "$WS_GUID" --analytics-query "DuoSecurityAuthentication_CL | count" --query "[0].Count" -o tsv 2>/dev/null || echo 0; }
if [ "${WAIT_DATA:-0}" -gt 0 ]; then
  info "waiting up to ${WAIT_DATA}m for first events (pollers run on a schedule)..."
  C=0; for _ in $(seq 1 "$WAIT_DATA"); do C="$(get_count)"; [ "${C:-0}" -gt 0 ] 2>/dev/null && break; sleep 60; done
  [ "${C:-0}" -gt 0 ] 2>/dev/null && pass "data flowing ($C auth events)" || fail "no data after ${WAIT_DATA}m"
else
  info "auth events so far: $(get_count) (populate ~5-10 min after deploy; re-check, or use --wait-for-data 15)"
fi

# --- Summary ---
hr "Summary"
if [ "$FAILS" -eq 0 ]; then
  echo "  ALL STAGES PASSED. Connector + content deployed via the package and active."
else
  echo "  $FAILS check(s) FAILED — see above."
fi
exit $(( FAILS > 0 ? 1 : 0 ))
