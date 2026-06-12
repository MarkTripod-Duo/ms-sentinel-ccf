#!/usr/bin/env python3
"""Render Microsoft Sentinel dataConnectorDefinition + RestApiPoller PUT bodies for the scripted deploy.

Reads the three per-endpoint CCF connector folders under solution/Data Connectors/ and writes
`az rest`-ready PUT bodies into --out-dir, substituting the CCF/ARM placeholders with the real deployment
values — including literal Duo credentials so the pollers are active on deploy. This is the scripted/test
path (deploy-connector.sh, test-package-deployment.sh); the Content Hub package instead leaves the
credentials as Connect-time template literals. Using the source files directly keeps the deployed
connectors in lock-step with the packaged solution (no hand-copied drift).

Emits one line per rendered resource to stdout: "<kind> <name>".
"""

from __future__ import annotations

import argparse
import json
import os

# (folder, file prefix) for each per-endpoint connector.
CONNECTORS = [
    ("DuoSecurityAuth_CCF", "DuoSecurityAuth"),
    ("DuoSecurityActivity_CCF", "DuoSecurityActivity"),
    ("DuoSecurityTelephony_CCF", "DuoSecurityTelephony"),
]


def substitute(obj, mapping):
    """Recursively replace placeholder substrings inside every string value."""
    if isinstance(obj, dict):
        return {k: substitute(v, mapping) for k, v in obj.items()}
    if isinstance(obj, list):
        return [substitute(v, mapping) for v in obj]
    if isinstance(obj, str):
        for placeholder, value in mapping.items():
            obj = obj.replace(placeholder, value)
        return obj
    return obj


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src-root", required=True, help="the 'solution/Data Connectors' directory")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--duo-host", required=True, help="e.g. https://api-XXXXXXXX.duosecurity.com")
    ap.add_argument("--ikey", required=True, help="Duo integration key")
    ap.add_argument("--skey", required=True, help="Duo secret key")
    ap.add_argument("--dce", required=True)
    ap.add_argument("--dcr-id", required=True)
    args = ap.parse_args()

    # {{BaseUrl}} is the CCF host token; [[parameters('ikey')] / [[parameters('skey')] are the escaped
    # Connect-time literals in the source — here we resolve all three to real values for an active deploy.
    mapping = {
        "{{BaseUrl}}": args.duo_host,
        "[[parameters('ikey')]": args.ikey,
        "[[parameters('skey')]": args.skey,
        "{{dataCollectionEndpoint}}": args.dce,
        "{{dataCollectionRuleImmutableId}}": args.dcr_id,
    }
    os.makedirs(args.out_dir, exist_ok=True)

    for folder, prefix in CONNECTORS:
        base = os.path.join(args.src_root, folder)

        # Connector definition (UI). connectorUiConfig has no request placeholders; substitute() is a no-op.
        definition = json.load(open(os.path.join(base, f"{prefix}_ConnectorDefinition.json")))
        def_id = definition["properties"]["connectorUiConfig"]["id"]
        def_body = {"kind": definition["kind"], "properties": substitute(definition["properties"], mapping)}
        if "availability" in definition:
            def_body["availability"] = definition["availability"]
        json.dump(def_body, open(os.path.join(args.out_dir, f"definition_{def_id}.json"), "w"), indent=2)
        print("definition", def_id)

        # RestApiPoller connection — active on deploy (isActive=true) with resolved Duo credentials.
        for poller in json.load(open(os.path.join(base, f"{prefix}_PollingConfig.json"))):
            props = substitute(poller["properties"], mapping)
            props["isActive"] = True
            body = {"kind": poller["kind"], "properties": props}
            name = poller["name"]
            json.dump(body, open(os.path.join(args.out_dir, f"poller_{name}.json"), "w"), indent=2)
            print("poller", name)


if __name__ == "__main__":
    main()
