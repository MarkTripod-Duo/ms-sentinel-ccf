#!/usr/bin/env bash
#
# Deploy the Duo HMAC signing proxy (Azure Function) and print the values the Microsoft Sentinel
# connector needs: the proxy base URL and a function key.
#
# Prereqs: az CLI (logged in), Azure Functions Core Tools (`func`), an existing resource group.
#
# Usage:
#   ./deploy-proxy.sh \
#       --resource-group <rg> \
#       --app-name       <globally-unique-function-app-name> \
#       --duo-host        api-XXXXXXXX.duosecurity.com \
#       --duo-ikey        DIXXXXXXXXXXXXXXXXXX \
#       --duo-skey        <duo-secret-key> \
#       [--location       eastus] \
#       [--skip-quota-check]
#
set -euo pipefail

LOCATION="eastus"
SKIP_QUOTA_CHECK=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group)   RG="$2"; shift 2 ;;
    --app-name)         APP="$2"; shift 2 ;;
    --duo-host)         DUO_HOST="$2"; shift 2 ;;
    --duo-ikey)         DUO_IKEY="$2"; shift 2 ;;
    --duo-skey)         DUO_SKEY="$2"; shift 2 ;;
    --location)         LOCATION="$2"; shift 2 ;;
    --skip-quota-check) SKIP_QUOTA_CHECK=true; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

: "${RG:?--resource-group is required}"
: "${APP:?--app-name is required}"
: "${DUO_HOST:?--duo-host is required}"
: "${DUO_IKEY:?--duo-ikey is required}"
: "${DUO_SKEY:?--duo-skey is required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROXY_DIR="$(cd "$SCRIPT_DIR/../signing-proxy" && pwd)"

# --- Preflight: verify the target region has spare compute (vCPU) quota --------------------
# The Consumption (Y1) Function plan consumes regional vCPU quota. New/free subscriptions often
# have a limit of 0 in popular regions, which fails ARM preflight with "SubscriptionIsOverQuotaForSku".
# Catch that here with an actionable message instead of a cryptic deployment error.
check_region_quota() {
  echo "==> [preflight] Checking compute quota in '$LOCATION'..."
  local usage limit current available
  usage="$(az vm list-usage -l "$LOCATION" --query "[?name.value=='cores'].[limit, currentValue]" -o tsv 2>/dev/null || true)"
  if [[ -z "$usage" ]]; then
    echo "    WARN: couldn't read vCPU quota for '$LOCATION' (permissions or bad region name); skipping check." >&2
    return 0
  fi
  limit="$(printf '%s\n' "$usage" | awk 'NR==1{print $1}')"
  current="$(printf '%s\n' "$usage" | awk 'NR==1{print $2}')"
  if ! [[ "$limit" =~ ^[0-9]+$ && "$current" =~ ^[0-9]+$ ]]; then
    echo "    WARN: couldn't parse quota values (limit='$limit' used='$current'); skipping check." >&2
    return 0
  fi
  available=$(( limit - current ))
  echo "    Total Regional vCPUs in '$LOCATION': ${current}/${limit} used, ${available} available."
  if (( available < 1 )); then
    cat >&2 <<EOF

ERROR: '$LOCATION' has no spare compute quota (need 1 vCPU, ${available} available) — the
       Consumption Function plan cannot deploy here. Options:
         * Re-run with another region:   --location eastus2   (or westus2 / centralus)
         * Find a region with quota:
             for L in eastus2 westus2 centralus westus3; do \\
               echo "== \$L =="; az vm list-usage -l "\$L" -o table | grep "Total Regional vCPUs"; done
         * Request an increase:  Portal > Subscriptions > Usage + quotas > Compute
       Re-run with --skip-quota-check to bypass this check.
EOF
    exit 1
  fi
}

if [[ "$SKIP_QUOTA_CHECK" == "true" ]]; then
  echo "==> [preflight] Skipping quota check (--skip-quota-check)."
else
  check_region_quota
fi

echo "==> [1/3] Deploying infrastructure (Function App + Storage + App Insights + Key Vault)..."
az deployment group create \
  --resource-group "$RG" \
  --template-file "$PROXY_DIR/azuredeploy.json" \
  --parameters functionAppName="$APP" duoApiHost="$DUO_HOST" duoIkey="$DUO_IKEY" duoSkey="$DUO_SKEY" location="$LOCATION" \
  --output none
echo "    done."

echo "==> [2/3] Publishing function code (duo-hmac signer)..."
( cd "$PROXY_DIR" && func azure functionapp publish "$APP" --python )

echo "==> [3/3] Reading connection values for Microsoft Sentinel..."
HOSTNAME="$(az functionapp show -g "$RG" -n "$APP" --query defaultHostName -o tsv)"
FUNC_KEY="$(az functionapp keys list -g "$RG" -n "$APP" --query functionKeys.default -o tsv)"

cat <<EOF

============================================================
 Signing proxy deployed. Use these in the Sentinel connector:
------------------------------------------------------------
 Signing proxy base URL : https://${HOSTNAME}/api
 Function key           : ${FUNC_KEY}
------------------------------------------------------------
 Smoke test (replace the epoch-ms window; maxtime <= now-2min):
   curl "https://${HOSTNAME}/api/duo/authentication?mintime=1717200000000&maxtime=1717203600000&limit=5" \\
        -H "x-functions-key: ${FUNC_KEY}"
============================================================
EOF
