#!/usr/bin/env python3
"""Assemble a self-contained, deployable mainTemplate.json from the solution source.

Reads every artifact under solution/ (connector definition, pollers, DCR, tables, parsers, analytic
rules, hunting queries, workbook) and emits one ARM template that creates the whole Sentinel-side
solution: DCE + tables + DCR + connector definition + pollers (wired to the signing proxy) + parsers
+ rules + hunts + workbook. The signing-proxy Azure Function is deployed separately
(signing-proxy/azuredeploy.json); this template's createUiDefinition collects its URL + key.

This is a *deployable* artifact (one-click ARM install). It is intentionally NOT the Content Hub
gallery format (no contentPackages/metadata resources) — for that, use deploy/stage-for-packaging.sh
with the official V3 tool.

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
CCP = os.path.join(SOL, "Data Connectors", "DuoSecurityCCF_ccp")
OUT_DIR = os.path.join(SOL, "Package")

# ARM expressions for the deploy-time wiring.
WS_LOC = "[parameters('workspace-location')]"
WS_RES_ID = "[resourceId('Microsoft.OperationalInsights/workspaces', parameters('workspace'))]"
DCE_RES_ID = "[resourceId('Microsoft.Insights/dataCollectionEndpoints', variables('dceName'))]"
DCE_ENDPOINT = "[reference(resourceId('Microsoft.Insights/dataCollectionEndpoints', variables('dceName')), '2022-06-01').logsIngestion.endpoint]"
DCR_IMMUTABLE = "[reference(resourceId('Microsoft.Insights/dataCollectionRules', variables('dcrName')), '2022-06-01').immutableId]"
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

    # --- DCE ---
    resources.append({
        "type": "Microsoft.Insights/dataCollectionEndpoints",
        "apiVersion": "2022-06-01",
        "name": "[variables('dceName')]",
        "location": WS_LOC,
        "properties": {"networkAcls": {"publicNetworkAccess": "Enabled"}},
    })

    # --- Tables ---
    table_dep_ids = []
    for t in load_json(os.path.join(CCP, "DuoSecurity_Tables.json")):
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

    # --- DCR ---
    dcr = load_json(os.path.join(CCP, "DuoSecurity_DCR.json"))[0]
    dprops = dcr["properties"]
    dprops["destinations"]["logAnalytics"][0]["workspaceResourceId"] = WS_RES_ID
    dprops["dataCollectionEndpointId"] = DCE_RES_ID
    resources.append({
        "type": "Microsoft.Insights/dataCollectionRules",
        "apiVersion": "2022-06-01",
        "name": "[variables('dcrName')]",
        "location": WS_LOC,
        "dependsOn": ["[resourceId('Microsoft.Insights/dataCollectionEndpoints', variables('dceName'))]"] + table_dep_ids,
        "properties": dprops,
    })

    # --- Connector definition ---
    definition = load_json(os.path.join(CCP, "DuoSecurity_DataConnectorDefinition.json"))
    def_id = definition["properties"]["connectorUiConfig"]["id"]
    resources.append({
        "type": "Microsoft.OperationalInsights/workspaces/providers/dataConnectorDefinitions",
        "apiVersion": "2022-09-01-preview",
        "name": sentinel_name(def_id),
        "location": WS_LOC,
        "kind": "Customizable",
        "properties": definition["properties"],
    })
    def_dep = f"[resourceId('Microsoft.OperationalInsights/workspaces/providers/dataConnectorDefinitions', parameters('workspace'), 'Microsoft.SecurityInsights', '{def_id}')]"
    dcr_dep = "[resourceId('Microsoft.Insights/dataCollectionRules', variables('dcrName'))]"

    # --- Pollers ---
    for p in load_json(os.path.join(CCP, "DuoSecurity_PollingConfig.json")):
        pr = p["properties"]
        suffix = pr["request"]["apiEndpoint"].split("}}")[-1]  # e.g. /duo/authentication
        pr["request"]["apiEndpoint"] = f"[concat(parameters('proxyBaseUrl'), '{suffix}')]"
        pr["auth"]["ApiKey"] = "[parameters('functionKey')]"
        pr["dcrConfig"]["dataCollectionEndpoint"] = DCE_ENDPOINT
        pr["dcrConfig"]["dataCollectionRuleImmutableId"] = DCR_IMMUTABLE
        resources.append({
            "type": "Microsoft.OperationalInsights/workspaces/providers/dataConnectors",
            "apiVersion": "2022-10-01-preview",
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
        "metadata": {"comments": "Self-contained deployable Cisco Duo CCF solution (connector + content). Deploy the signing proxy separately via signing-proxy/azuredeploy.json."},
        "parameters": {
            "workspace": {"type": "string", "metadata": {"description": "Sentinel-enabled Log Analytics workspace name."}},
            "workspace-location": {"type": "string", "defaultValue": "[resourceGroup().location]", "metadata": {"description": "Workspace region."}},
            "proxyBaseUrl": {"type": "string", "metadata": {"description": "Duo signing proxy base URL, e.g. https://<app>.azurewebsites.net/api"}},
            "functionKey": {"type": "securestring", "metadata": {"description": "Azure Functions key for the signing proxy."}},
        },
        "variables": {
            "dceName": "[concat('duo-ccf-dce-', uniqueString(resourceGroup().id, parameters('workspace')))]",
            "dcrName": "[concat('duo-ccf-dcr-', uniqueString(resourceGroup().id, parameters('workspace')))]",
        },
        "resources": resources,
        "outputs": {
            "tablesCreated": {"type": "string", "value": "DuoSecurityAuthentication_CL, DuoSecurityActivity_CL, DuoSecurityTelephony_CL"},
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
