#!/usr/bin/env bash
#
# Stage solution/ into an Azure-Sentinel clone so the official V3 packaging tool can build the
# Content Hub (marketplace/Partner-Center-publishable) package. The V3 tool itself can't run
# standalone in this repo (it needs the clone's Tools/ and .script/ helpers and a Solutions/ path).
#
# Usage:
#   ./stage-for-packaging.sh [--sentinel-repo <path>] [--run]
#     --sentinel-repo  path to an Azure-Sentinel clone (default: ~/code/Azure-Sentinel)
#     --run            also invoke the V3 tool via pwsh after staging (best-effort)
#
set -euo pipefail

SENTINEL="$HOME/code/Azure-Sentinel"
RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sentinel-repo) SENTINEL="$2"; shift 2 ;;
    --run)           RUN=true; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NAME="DuoSecurityCCF"
DEST="$SENTINEL/Solutions/$NAME"

[ -d "$SENTINEL/Solutions" ] && [ -d "$SENTINEL/Tools/Create-Azure-Sentinel-Solution/V3" ] || {
  echo "ERROR: '$SENTINEL' doesn't look like an Azure-Sentinel clone (missing Solutions/ or the V3 tool)." >&2
  echo "       Pass --sentinel-repo <path>." >&2
  exit 1
}

echo "==> Staging solution/ into $DEST ..."
mkdir -p "$DEST/Data" "$DEST/Data Connectors"
cp -R "$ROOT/solution/Data Connectors/." "$DEST/Data Connectors/"   # the three DuoSecurity*_CCF connector folders
cp -R "$ROOT/solution/Parsers" "$DEST/"
cp -R "$ROOT/solution/Analytic Rules" "$DEST/"
cp -R "$ROOT/solution/Hunting Queries" "$DEST/"
cp -R "$ROOT/solution/Workbooks" "$DEST/"
cp "$ROOT/solution/Data/Solution_DuoSecurityCCF.json" "$DEST/Data/"
cp "$ROOT/solution/SolutionMetadata.json" "$DEST/"
cp "$ROOT/solution/ReleaseNotes.md" "$DEST/"

# Point BasePath at the staged folder (required by the V3 tool).
python3 - "$DEST" <<'PY'
import json, sys, os
dest = sys.argv[1]
f = os.path.join(dest, "Data", "Solution_DuoSecurityCCF.json")
d = json.load(open(f)); d["BasePath"] = dest + "/"
json.dump(d, open(f, "w"), indent=2)
print(f"  BasePath set to {dest}/")
PY

echo "    staged."
DATA_FOLDER="$DEST/Data"

if $RUN; then
  if command -v pwsh >/dev/null 2>&1; then
    echo "==> Running the V3 tool (feeding data-folder path to the prompt)..."
    ( cd "$SENTINEL/Tools/Create-Azure-Sentinel-Solution/V3" && printf '%s\n' "$DATA_FOLDER" | pwsh -NoProfile -File ./createSolutionV3.ps1 ) || \
      echo "    (V3 run did not complete cleanly — run it manually, see below)"
  else
    echo "    pwsh not found; install PowerShell 7 to use --run."
  fi
fi

cat <<EOF

============================================================
 Staged at: $DEST
 Run the official V3 packaging tool:
   cd "$SENTINEL/Tools/Create-Azure-Sentinel-Solution/V3"
   pwsh ./createSolutionV3.ps1
   # at the "Enter solution data file path" prompt, paste:
   $DATA_FOLDER
 Output: $DEST/Package/{mainTemplate.json, createUiDefinition.json, <version>.zip}

 Before publishing: set real publisherId/Author/offerId in the staged SolutionMetadata.json /
 Solution_DuoSecurityCCF.json. Re-run this script after changing solution/ to re-stage.
============================================================
EOF
