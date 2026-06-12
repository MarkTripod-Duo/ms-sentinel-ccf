"""Validate the three per-endpoint Cisco Duo CCF connectors (native CiscoDuo auth, no proxy).

    python -m pytest tests/

For each connector folder this checks the definition + poller + DCR + table for:
  - native ``auth.type == CiscoDuo`` with the ikey/skey Connect-time literals (no proxy / function key),
  - a direct Duo Admin API endpoint (``{{BaseUrl}}/admin/v2/logs/<type>``),
  - stream-name consistency across poller / DCR / table, and
  - a Connect UI that collects BaseUrl / ikey / skey.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
DC = REPO / "solution" / "Data Connectors"

# folder, file prefix, table, Duo log type, events JSON path
CONNECTORS = [
    ("DuoSecurityAuth_CCF", "DuoSecurityAuth", "DuoSecurityAuthentication_CL", "authentication", "$.response.authlogs"),
    ("DuoSecurityActivity_CCF", "DuoSecurityActivity", "DuoSecurityActivity_CL", "activity", "$.response.items"),
    ("DuoSecurityTelephony_CCF", "DuoSecurityTelephony", "DuoSecurityTelephony_CL", "telephony", "$.response.items"),
]
PARAMS = "folder,prefix,table,logtype,events"


def _load(path: Path) -> dict | list:
    return json.loads(Path(path).read_text())


def _poller(folder, prefix):
    pollers = _load(DC / folder / f"{prefix}_PollingConfig.json")
    assert isinstance(pollers, list) and len(pollers) == 1
    return pollers[0]["properties"]


@pytest.mark.parametrize(PARAMS, CONNECTORS)
def test_all_json_valid(folder, prefix, table, logtype, events):
    files = sorted(p.name for p in (DC / folder).glob("*.json"))
    assert files == sorted(
        [f"{prefix}_ConnectorDefinition.json", f"{prefix}_DCR.json",
         f"{prefix}_PollingConfig.json", f"{prefix}_Table.json"]
    )
    for p in (DC / folder).glob("*.json"):
        _load(p)  # raises on malformed JSON


@pytest.mark.parametrize(PARAMS, CONNECTORS)
def test_poller_uses_native_ciscoduo_auth(folder, prefix, table, logtype, events):
    props = _poller(folder, prefix)
    auth = props["auth"]
    assert auth["type"] == "CiscoDuo"
    assert auth["APIKey"] == "[[parameters('ikey')]"
    assert auth["ClientSecret"] == "[[parameters('skey')]"
    # direct Duo endpoint — no proxy, no function key anywhere
    assert props["request"]["apiEndpoint"] == "{{BaseUrl}}/admin/v2/logs/" + logtype
    blob = json.dumps(props).lower()
    assert "proxy" not in blob and "functionkey" not in blob and "x-functions-key" not in blob
    # time window + cursor paging preserved
    assert props["request"]["queryTimeFormat"] == "UnixTimestampInMills"
    assert props["paging"]["pagingType"] == "NextPageToken"
    assert props["paging"]["nextPageTokenJsonPath"] == "$.response.metadata.next_offset"
    assert props["response"]["eventsJsonPaths"] == [events]


@pytest.mark.parametrize(PARAMS, CONNECTORS)
def test_stream_table_dcr_consistency(folder, prefix, table, logtype, events):
    props = _poller(folder, prefix)
    dcr = _load(DC / folder / f"{prefix}_DCR.json")["properties"]
    schema = _load(DC / folder / f"{prefix}_Table.json")[0]["properties"]["schema"]
    stream = props["dcrConfig"]["streamName"]
    assert stream == f"Custom-{table}"
    assert list(dcr["streamDeclarations"].keys()) == [stream]
    flow = dcr["dataFlows"][0]
    assert flow["streams"] == [stream] and flow["outputStream"] == stream
    assert "TimeGenerated" in flow["transformKql"]
    assert schema["name"] == table
    assert "TimeGenerated" in {c["name"] for c in schema["columns"]}


@pytest.mark.parametrize(PARAMS, CONNECTORS)
def test_connect_ui_collects_duo_credentials(folder, prefix, table, logtype, events):
    cfg = _load(DC / folder / f"{prefix}_ConnectorDefinition.json")["properties"]["connectorUiConfig"]
    assert cfg["graphQueriesTableName"] == table
    assert _poller(folder, prefix)["connectorDefinitionName"] == cfg["id"]
    names = {
        ins["parameters"]["name"]
        for step in cfg["instructionSteps"]
        for ins in step.get("instructions", [])
        if "name" in ins.get("parameters", {})
    }
    assert {"BaseUrl", "ikey", "skey", "connect"}.issubset(names)


def test_telephony_transform_renames_type():
    dcr = _load(DC / "DuoSecurityTelephony_CCF" / "DuoSecurityTelephony_DCR.json")["properties"]
    transform = dcr["dataFlows"][0]["transformKql"]
    assert "telephony_type = ['type']" in transform
