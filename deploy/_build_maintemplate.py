#!/usr/bin/env python3
"""Assemble a self-contained, deployable mainTemplate.json from the solution source.

Reads every artifact under solution/ (three per-endpoint CCF connectors — authentication, activity,
telephony — each with its connector definition, poller, DCR and table, plus the parsers, analytic rules,
hunting queries and workbook) and emits one ARM template that creates the whole Sentinel-side solution:
a shared DCE + 3 tables + 3 DCRs + 3 connector definitions + 3 pollers + parsers + rules + hunts +
workbook.

Authentication is the built-in **CiscoDuo** CCF auth type (HMAC signing in the polling engine) — no
signing proxy. The pollers call Duo directly; the Duo credentials (API host / integration key / secret
key) are entered on each connector page at Connect time, so they are NOT ARM parameters and no secret is
baked into the deployment. The poller carries them as escaped template literals
(``[concat(parameters('BaseUrl'),...)]`` / ``[parameters('ikey')]`` / ``[parameters('skey')]``) that
Sentinel resolves when the operator clicks **Connect**.

This is a *deployable* artifact (one-click ARM install). It is intentionally NOT the Content Hub gallery
format (no contentPackages/metadata resources) — for that, use deploy/stage-for-packaging.sh with the
official V3 tool.

Usage: python3 deploy/_build_maintemplate.py   ->   writes solution/Package/mainTemplate.json
"""

from __future__ import annotations

import glob
import json
import os
import re

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOL = os.path.join(ROOT, "solution")
DC = os.path.join(SOL, "Data Connectors")
OUT_DIR = os.path.join(SOL, "Package")

# One CCF connector per Duo log endpoint. Each folder holds <prefix>_{ConnectorDefinition,PollingConfig,
# DCR,Table}.json and ships its own single-stream DCR + table.
CONNECTORS = [
    {"key": "auth", "folder": "DuoSecurityAuth_CCF", "prefix": "DuoSecurityAuth"},
    {"key": "activity", "folder": "DuoSecurityActivity_CCF", "prefix": "DuoSecurityActivity"},
    {"key": "telephony", "folder": "DuoSecurityTelephony_CCF", "prefix": "DuoSecurityTelephony"},
]

# ARM expressions for the deploy-time wiring.
WS_LOC = "[parameters('workspace-location')]"
WS_RES_ID = "[resourceId('Microsoft.OperationalInsights/workspaces', parameters('workspace'))]"
DCE_RES_ID = "[resourceId('Microsoft.Insights/dataCollectionEndpoints', variables('dceName'))]"
DCE_ENDPOINT = "[reference(resourceId('Microsoft.Insights/dataCollectionEndpoints', variables('dceName')), '2022-06-01').logsIngestion.endpoint]"
WORKBOOK_GUID = "c587e550-f8fc-4950-9afe-8adb83e986bd"

DUR = {"m": "PT{}M", "h": "PT{}H", "d": "P{}D"}
OP = {"gt": "GreaterThan", "lt": "LessThan", "eq": "Equal", "ne": "NotEqual"}


def iso_dur(s: str) -> str:
    s = str(s)
    return DUR[s[-1]].format(int(re.match(r"\d+", s).group()))


def ws_child_name(child: str) -> str:
    return f"[format('{{0}}/{{1}}', parameters('workspace'), '{child}')]"


def sentinel_name(provider_child: str) -> str:
    return f"[concat(parameters('workspace'), '/Microsoft.SecurityInsights/{provider_child}')]"


def load_json(path):
    return json.load(open(path))


def load_yaml(path):
    return yaml.safe_load(open(path))


def saved_search(sid, category, display, query, alias="", params=""):
    return {
        "type": "Microsoft.OperationalInsights/workspaces/savedSearches",
        "apiVersion": "2020-08-01",
        "name": ws_child_name(sid),
        "properties": {
            "category": category,
            "displayName": display,
            "query": query,
            "functionAlias": alias,
            "functionParameters": params,
            "version": 2,
        },
    }


def parser_param_signature(parser_params):
    # vim* parsers carry a ParserParams list -> "name:type=default,..."
    parts = []
    for p in parser_params or []:
        parts.append(f"{p['Name']}:{p['Type']}={p['Default']}")
    return ",".join(parts)


def build():
    resources = []
    variables = {
        "dceName": "[concat('duo-ccf-dce-', uniqueString(resourceGroup().id, parameters('workspace')))]",
    }

    # --- Shared DCE ---
    resources.append({
        "type": "Microsoft.Insights/dataCollectionEndpoints",
        "apiVersion": "2022-06-01",
        "name": "[variables('dceName')]",
        "location": WS_LOC,
        "properties": {"networkAcls": {"publicNetworkAccess": "Enabled"}},
    })
    dce_dep = "[resourceId('Microsoft.Insights/dataCollectionEndpoints', variables('dceName'))]"

    # --- One connector set (table + DCR + definition + poller) per endpoint ---
    for c in CONNECTORS:
        folder = os.path.join(DC, c["folder"])
        prefix = c["prefix"]
        dcr_var = f"dcr{c['key'].capitalize()}Name"
        variables[dcr_var] = (
            f"[concat('duo-ccf-dcr-{c['key']}-', uniqueString(resourceGroup().id, parameters('workspace')))]"
        )

        # Tables
        table_dep_ids = []
        for t in load_json(os.path.join(folder, f"{prefix}_Table.json")):
            tname = t["properties"]["schema"]["name"]
            resources.append({
                "type": "Microsoft.OperationalInsights/workspaces/tables",
                "apiVersion": "2022-10-01",
                "name": ws_child_name(tname),
                "properties": t["properties"],
            })
            table_dep_ids.append(
                f"[resourceId('Microsoft.OperationalInsights/workspaces/tables', parameters('workspace'), '{tname}')]"
            )

        # DCR (single stream, kind Direct)
        dcr = load_json(os.path.join(folder, f"{prefix}_DCR.json"))
        dprops = dcr["properties"]
        dprops["destinations"]["logAnalytics"][0]["workspaceResourceId"] = WS_RES_ID
        dprops["dataCollectionEndpointId"] = DCE_RES_ID
        resources.append({
            "type": "Microsoft.Insights/dataCollectionRules",
            "apiVersion": "2022-06-01",
            "name": f"[variables('{dcr_var}')]",
            "kind": dcr.get("kind", "Direct"),
            "location": WS_LOC,
            "dependsOn": [dce_dep] + table_dep_ids,
            "properties": dprops,
        })
        dcr_dep = f"[resourceId('Microsoft.Insights/dataCollectionRules', variables('{dcr_var}'))]"
        dcr_immutable = (
            f"[reference(resourceId('Microsoft.Insights/dataCollectionRules', variables('{dcr_var}')), '2022-06-01').immutableId]"
        )

        # Connector definition (Connect UI)
        definition = load_json(os.path.join(folder, f"{prefix}_ConnectorDefinition.json"))
        def_id = definition["properties"]["connectorUiConfig"]["id"]
        def_res = {
            "type": "Microsoft.OperationalInsights/workspaces/providers/dataConnectorDefinitions",
            "apiVersion": "2022-09-01-preview",
            "name": sentinel_name(def_id),
            "location": WS_LOC,
            "kind": "Customizable",
            "properties": definition["properties"],
        }
        if "availability" in definition:
            def_res["availability"] = definition["availability"]
        resources.append(def_res)
        def_dep = (
            f"[resourceId('Microsoft.OperationalInsights/workspaces/providers/dataConnectorDefinitions', "
            f"parameters('workspace'), 'Microsoft.SecurityInsights', '{def_id}')]"
        )

        # Poller — credentials resolved at Connect time (escaped template literals, no ARM secrets).
        for p in load_json(os.path.join(folder, f"{prefix}_PollingConfig.json")):
            pr = p["properties"]
            suffix = pr["request"]["apiEndpoint"].split("{{BaseUrl}}")[-1]  # e.g. /admin/v2/logs/authentication
            pr["request"]["apiEndpoint"] = f"[[concat(parameters('BaseUrl'), '{suffix}')]"
            # pr["auth"] keeps the source CiscoDuo block ([[parameters('ikey')] / [[parameters('skey')]).
            pr["dcrConfig"]["dataCollectionEndpoint"] = DCE_ENDPOINT
            pr["dcrConfig"]["dataCollectionRuleImmutableId"] = dcr_immutable
            resources.append({
                "type": "Microsoft.OperationalInsights/workspaces/providers/dataConnectors",
                "apiVersion": "2023-02-01-preview",
                "name": sentinel_name(p["name"]),
                "location": WS_LOC,
                "kind": "RestApiPoller",
                "dependsOn": [def_dep, dcr_dep],
                "properties": pr,
            })

    # --- Parsers (savedSearches) ---
    cd = load_yaml(os.path.join(SOL, "Parsers", "CiscoDuo.yaml"))
    resources.append(saved_search("CiscoDuo", "Function", cd["FunctionName"], cd["FunctionQuery"], cd["FunctionAlias"], ""))
    for f in sorted(glob.glob(os.path.join(SOL, "Parsers", "ASim", "*.yaml"))):
        a = load_yaml(f)
        resources.append(saved_search(a["ParserName"], "Function", a["ParserName"], a["ParserQuery"], a["ParserName"], parser_param_signature(a.get("ParserParams"))))

    # --- Analytic rules (alertRules) ---
    for f in sorted(glob.glob(os.path.join(SOL, "Analytic Rules", "*.yaml"))):
        r = load_yaml(f)
        props = {
            "displayName": r["name"],
            "description": (r.get("description") or "").strip().strip("'"),
            "severity": r["severity"],
            "enabled": True,
            "query": r["query"],
            "queryFrequency": iso_dur(r["queryFrequency"]),
            "queryPeriod": iso_dur(r["queryPeriod"]),
            "triggerOperator": OP[r["triggerOperator"]],
            "triggerThreshold": r["triggerThreshold"],
            "suppressionDuration": "PT5H",
            "suppressionEnabled": False,
            "tactics": r.get("tactics", []),
            "techniques": r.get("relevantTechniques", []),
        }
        if r.get("entityMappings"):
            props["entityMappings"] = r["entityMappings"]
        resources.append({
            "type": "Microsoft.OperationalInsights/workspaces/providers/alertRules",
            "apiVersion": "2023-02-01",
            "name": sentinel_name(r["id"]),
            "kind": "Scheduled",
            "properties": props,
        })

    # --- Hunting queries (savedSearches) ---
    for f in sorted(glob.glob(os.path.join(SOL, "Hunting Queries", "*.yaml"))):
        h = load_yaml(f)
        sid = "duohunt" + h["id"].replace("-", "")[:18]
        ss = saved_search(sid, "Hunting Queries", h["name"], h["query"])
        ss["properties"]["tags"] = [
            {"name": "description", "value": (h.get("description") or "").strip().strip("'").replace("\n", " ")[:255]},
            {"name": "tactics", "value": ",".join(h.get("tactics", []))},
        ]
        resources.append(ss)

    # --- Workbook ---
    wb_content = open(os.path.join(SOL, "Workbooks", "CiscoDuo.json")).read()
    resources.append({
        "type": "Microsoft.Insights/workbooks",
        "apiVersion": "2022-04-01",
        "name": WORKBOOK_GUID,
        "location": WS_LOC,
        "kind": "shared",
        "properties": {
            "displayName": "Cisco Duo Security",
            "serializedData": wb_content,
            "version": "1.0",
            "sourceId": WS_RES_ID,
            "category": "sentinel",
        },
    })

    template = {
        "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
        "contentVersion": "1.0.0.0",
        "metadata": {"comments": "Self-contained deployable Cisco Duo CCF solution (3 per-endpoint connectors + content). Authentication uses the built-in CiscoDuo auth type — no signing proxy. Enter Duo credentials on each connector page and click Connect."},
        "parameters": {
            "workspace": {"type": "string", "metadata": {"description": "Sentinel-enabled Log Analytics workspace name."}},
            "workspace-location": {"type": "string", "defaultValue": "[resourceGroup().location]", "metadata": {"description": "Workspace region."}},
        },
        "variables": variables,
        "resources": resources,
        "outputs": {
            "tablesCreated": {"type": "string", "value": "DuoSecurityAuthentication_CL, DuoSecurityActivity_CL, DuoSecurityTelephony_CL"},
            "connectInstructions": {"type": "string", "value": "Open each Cisco Duo connector in Microsoft Sentinel > Data connectors, enter the Duo API host / integration key / secret key, and click Connect."},
        },
    }

    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, "mainTemplate.json")
    json.dump(template, open(out, "w"), indent=2)
    counts = {}
    for r in resources:
        counts[r["type"].split("/")[-1]] = counts.get(r["type"].split("/")[-1], 0) + 1
    print(f"wrote {out}")
    print(f"  {len(resources)} resources: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))


if __name__ == "__main__":
    build()
