"""Unit tests for the legacy Duo signing proxy core logic.

Runs with the standard library + pytest only. The `azure-functions` and `duo-hmac` packages are not
required (the one signing test self-skips if `duo-hmac` is absent).

    python -m pytest tests/

These cover the signing proxy, which is retained only until the built-in **CiscoDuo** CCF auth type is
verified live (then the proxy and this file are removed). The active per-endpoint connectors are validated
in test_connector_config.py.
"""

from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
PROXY = REPO / "signing-proxy"
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


def test_apply_mintime_lookback():
    # off by default (0 seconds) -> unchanged
    assert core.apply_mintime_lookback({"mintime": "1717203600000"}, 0) == {"mintime": "1717203600000"}
    # subtracts lookback*1000 ms from mintime, leaves maxtime alone
    out = core.apply_mintime_lookback({"mintime": "1717203600000", "maxtime": "1717203720000"}, 180)
    assert out["mintime"] == str(1717203600000 - 180 * 1000)
    assert out["maxtime"] == "1717203720000"
    # no-op when mintime is absent or non-numeric
    assert core.apply_mintime_lookback({"maxtime": "5"}, 300) == {"maxtime": "5"}
    assert core.apply_mintime_lookback({"mintime": "abc"}, 300) == {"mintime": "abc"}
    # does not mutate the caller's dict
    src = {"mintime": "1717203600000"}
    core.apply_mintime_lookback(src, 60)
    assert src == {"mintime": "1717203600000"}


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
