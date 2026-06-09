#!/usr/bin/env python3
"""Render Microsoft Sentinel dataConnectorDefinition + RestApiPoller request bodies.

Reads the canonical CCF source files under solution/Data Connectors/DuoSecurityCCF_ccp/ and writes
`az rest`-ready PUT bodies into --out-dir, substituting the CCF `{{placeholders}}` with the real
deployment values. Using the source files directly keeps the deployed connector in lock-step with
the packaged solution (no hand-copied drift).

Emits one line per rendered resource to stdout: "<kind> <name>".
"""

from __future__ import annotations

import argparse
import json
import os


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
    ap.add_argument("--src-dir", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--proxy-url", required=True)
    ap.add_argument("--function-key", required=True)
    ap.add_argument("--dce", required=True)
    ap.add_argument("--dcr-id", required=True)
    args = ap.parse_args()

    mapping = {
        "{{proxyBaseUrl}}": args.proxy_url,
        "{{functionKey}}": args.function_key,
        "{{dataCollectionEndpoint}}": args.dce,
        "{{dataCollectionRuleImmutableId}}": args.dcr_id,
    }
    os.makedirs(args.out_dir, exist_ok=True)

    # Connector definition (UI). connectorUiConfig has no placeholders; substitute() is a no-op here.
    definition = json.load(open(os.path.join(args.src_dir, "DuoSecurity_DataConnectorDefinition.json")))
    def_body = {"kind": definition["kind"], "properties": substitute(definition["properties"], mapping)}
    json.dump(def_body, open(os.path.join(args.out_dir, "definition.json"), "w"), indent=2)
    print("definition", definition["properties"]["connectorUiConfig"]["id"])

    # Three RestApiPoller connections.
    pollers = json.load(open(os.path.join(args.src_dir, "DuoSecurity_PollingConfig.json")))
    for poller in pollers:
        body = {"kind": poller["kind"], "properties": substitute(poller["properties"], mapping)}
        name = poller["name"]
        json.dump(body, open(os.path.join(args.out_dir, f"poller_{name}.json"), "w"), indent=2)
        print("poller", name)


if __name__ == "__main__":
    main()
