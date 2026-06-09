#!/usr/bin/env bash
#
# Build a self-contained, deployable solution package entirely in this repo (no Azure-Sentinel clone,
# no PowerShell): assembles solution/Package/{mainTemplate.json, createUiDefinition.json} from source.
#
# This produces a one-click-deployable ARM solution. For the official Content Hub gallery format,
# use deploy/stage-for-packaging.sh with the V3 tool instead.
#
# Requires: python3 with pyyaml.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG="$ROOT/solution/Package"

if ! python3 -c "import yaml" 2>/dev/null; then
  echo "ERROR: python3 is missing pyyaml. Install it:  python3 -m pip install --user pyyaml" >&2
  exit 1
fi

echo "==> Assembling mainTemplate.json from source..."
python3 "$SCRIPT_DIR/_build_maintemplate.py"

echo "==> Adding createUiDefinition.json..."
cp "$SCRIPT_DIR/createUiDefinition.json" "$PKG/createUiDefinition.json"

echo "==> Validating output JSON..."
python3 -c "import json; json.load(open('$PKG/mainTemplate.json')); json.load(open('$PKG/createUiDefinition.json')); print('  both valid JSON')"

if command -v zip >/dev/null 2>&1; then
  ( cd "$PKG" && zip -q -X duo-ccf-solution.zip mainTemplate.json createUiDefinition.json )
  echo "==> Zipped: solution/Package/duo-ccf-solution.zip"
fi

cat <<EOF

============================================================
 Package built in solution/Package/:
   mainTemplate.json        (deployable ARM solution)
   createUiDefinition.json  (portal Create wizard)

 Deploy it (after the signing proxy is up):
   az deployment group create -g <rg> \\
     --template-file solution/Package/mainTemplate.json \\
     --parameters workspace=<workspace> \\
                  proxyBaseUrl=https://<proxy-app>.azurewebsites.net/api \\
                  functionKey=<function-key>

 Or in the portal: "Deploy a custom template" > "Build your own" >
   load mainTemplate.json, then "Edit the UI definition" with createUiDefinition.json.

 Tip: validate first with  az deployment group validate  (same args).
============================================================
EOF
