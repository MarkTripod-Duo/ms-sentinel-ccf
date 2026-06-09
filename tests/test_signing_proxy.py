"""Unit tests for the Duo signing proxy core logic and the CCF solution's internal consistency.

Runs with the standard library + pytest only. The `azure-functions` and `duo-hmac` packages are not
required (the one signing test self-skips if `duo-hmac` is absent).

    python -m pytest tests/
"""

from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
PROXY = REPO / "signing-proxy"
CCP = REPO / "solution" / "Data Connectors" / "DuoSecurityCCF_ccp"
TESTS = Path(__file__).resolve().parent

import sys

sys.path.insert(0, str(PROXY))
import duo_proxy_core as core  # noqa: E402


def _load(path: Path) -> dict:
    return json.loads(path.read_text())


# --------------------------------------------------------------------------- proxy core logic


def test_log_types_cover_the_three_streams():
    assert set(core.LOG_TYPES) == {"authentication", "activity", "telephony"}
    assert core.duo_path_for("AUTHENTICATION")[0] == "/admin/v2/logs/authentication"
    assert core.duo_path_for("activity")[0] == "/admin/v2/logs/activity"
    assert core.duo_path_for("telephony")[0] == "/admin/v2/logs/telephony"
    assert core.duo_path_for("trust_monitor") is None


def test_events_keys_match_design():
    assert core.LOG_TYPES["authentication"][1] == "authlogs"
    assert core.LOG_TYPES["activity"][1] == "items"
    assert core.LOG_TYPES["telephony"][1] == "items"


def test_filter_params_strips_only_function_code():
    out = core.filter_params({"mintime": "1", "maxtime": "2", "next_offset": "x", "code": "secret"})
    assert out == {"mintime": "1", "maxtime": "2", "next_offset": "x"}


def test_ensure_https_prepends_scheme_idempotently():
    assert core.ensure_https("api-x.duosecurity.com/admin/v2/logs/authentication?limit=5") == (
        "https://api-x.duosecurity.com/admin/v2/logs/authentication?limit=5"
    )
    assert core.ensure_https("https://api-x.duosecurity.com/x") == "https://api-x.duosecurity.com/x"
    assert core.ensure_https("http://api-x.duosecurity.com/x") == "http://api-x.duosecurity.com/x"


def test_auth_next_offset_array_is_joined_to_string():
    payload = _load(TESTS / "sample_auth_v2.json")
    assert isinstance(payload["response"]["metadata"]["next_offset"], list)
    out = core.normalize_next_offset(copy.deepcopy(payload))
    assert out["response"]["metadata"]["next_offset"] == (
        "1749384005123,aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    )


@pytest.mark.parametrize("name", ["sample_activity_v2.json", "sample_telephony_v2.json"])
def test_string_next_offset_passes_through(name):
    payload = _load(TESTS / name)
    before = payload["response"]["metadata"]["next_offset"]
    out = core.normalize_next_offset(copy.deepcopy(payload))
    assert out["response"]["metadata"]["next_offset"] == before
    assert isinstance(out["response"]["metadata"]["next_offset"], str)


@pytest.mark.parametrize("payload", [{"stat": "OK"}, {"response": {}}, {"response": {"metadata": {}}}])
def test_normalize_tolerates_missing_metadata(payload):
    assert core.normalize_next_offset(copy.deepcopy(payload)) == payload


def test_duo_hmac_signs_request_when_available():
    pytest.importorskip("duo_hmac")
    from duo_hmac.duo_hmac import DuoHmac

    url, _body, headers = DuoHmac(
        "DIXXXXXXXXXXXXXXXXXX", "skeyskeyskeyskeyskey", "api-1234abcd.duosecurity.com"
    ).get_authentication_components("GET", "/admin/v2/logs/authentication", {"limit": "10"}, {})

    assert "Authorization" in headers
    assert any(h.lower() in ("date", "x-duo-date") for h in headers)
    assert "limit=10" in url
    # duo-hmac returns a scheme-less host/path?query; ensure_https() makes it usable by urllib
    assert not url.startswith(("http://", "https://"))
    assert core.ensure_https(url) == "https://" + url


# ------------------------------------------------------------------ CCF solution consistency

EXPECTED_STREAMS = {
    "Custom-DuoSecurityAuthentication_CL",
    "Custom-DuoSecurityActivity_CL",
    "Custom-DuoSecurityTelephony_CL",
}
EXPECTED_TABLES = {
    "DuoSecurityAuthentication_CL",
    "DuoSecurityActivity_CL",
    "DuoSecurityTelephony_CL",
}


def test_all_solution_json_is_valid():
    for path in CCP.glob("*.json"):
        _load(path)  # raises on malformed JSON


def test_pollers_reference_the_definition_and_expected_streams():
    definition = _load(CCP / "DuoSecurity_DataConnectorDefinition.json")
    definition_id = definition["properties"]["connectorUiConfig"]["id"]

    pollers = _load(CCP / "DuoSecurity_PollingConfig.json")
    assert isinstance(pollers, list) and len(pollers) == 3

    names = {p["name"] for p in pollers}
    assert len(names) == 3, "poller names must be unique"

    streams = set()
    for poller in pollers:
        props = poller["properties"]
        assert props["connectorDefinitionName"] == definition_id
        assert props["kind" if "kind" in props else "auth"]  # sanity: properties populated
        streams.add(props["dcrConfig"]["streamName"])
    assert streams == EXPECTED_STREAMS


def test_dcr_streams_match_pollers_and_tables():
    dcr = _load(CCP / "DuoSecurity_DCR.json")[0]["properties"]
    declared = set(dcr["streamDeclarations"].keys())
    assert declared == EXPECTED_STREAMS

    flow_streams = set()
    for flow in dcr["dataFlows"]:
        assert len(flow["streams"]) == 1
        stream = flow["streams"][0]
        flow_streams.add(stream)
        # custom-table connectors output to the same Custom-<table> stream
        assert flow["outputStream"] == stream
        assert "TimeGenerated" in flow["transformKql"]
    assert flow_streams == EXPECTED_STREAMS


def test_tables_match_expected_and_have_timegenerated():
    tables = _load(CCP / "DuoSecurity_Tables.json")
    names = {t["properties"]["schema"]["name"] for t in tables}
    assert names == EXPECTED_TABLES
    for table in tables:
        cols = {c["name"] for c in table["properties"]["schema"]["columns"]}
        assert "TimeGenerated" in cols


def test_poller_event_paths_are_correct_per_stream():
    pollers = _load(CCP / "DuoSecurity_PollingConfig.json")
    by_stream = {p["properties"]["dcrConfig"]["streamName"]: p for p in pollers}

    auth = by_stream["Custom-DuoSecurityAuthentication_CL"]["properties"]
    assert auth["response"]["eventsJsonPaths"] == ["$.response.authlogs"]
    assert auth["request"]["apiEndpoint"].endswith("/duo/authentication")
    assert auth["request"]["queryTimeFormat"] == "UnixTimestampInMills"
    assert auth["paging"]["nextPageTokenJsonPath"] == "$.response.metadata.next_offset"

    for stream in ("Custom-DuoSecurityActivity_CL", "Custom-DuoSecurityTelephony_CL"):
        props = by_stream[stream]["properties"]
        assert props["response"]["eventsJsonPaths"] == ["$.response.items"]
