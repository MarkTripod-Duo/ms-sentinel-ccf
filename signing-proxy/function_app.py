"""Duo Admin API v2 logs — HMAC-SHA1 signing proxy for Microsoft Sentinel CCF.

Microsoft Sentinel's Codeless Connector Framework (RestApiPoller) can only authenticate with
Basic / APIKey / OAuth2 / JWT, none of which can produce Duo's per-request HMAC-SHA1 signature.
This Azure Function is the minimal bridge: it receives a CCF poll, signs the intended Duo request
with the pure-Python `duo-hmac` library, forwards it to Duo, and returns Duo's JSON verbatim
(normalizing only the authentication-log ``next_offset`` array into a string so CCF's NextPageToken
pager can resend it). All time-windowing and pagination logic stays in the codeless CCF connector.

Routes (one per Duo v2 log stream):
    GET /api/duo/authentication
    GET /api/duo/activity
    GET /api/duo/telephony

Auth: Azure Functions function key (``x-functions-key`` header), supplied by CCF's APIKey auth.
Secrets: DUO_SKEY is read from an app setting backed by a Key Vault reference; the Function's
managed identity never exposes it to Sentinel.
"""

from __future__ import annotations

import json
import logging
import os
import urllib.error
import urllib.request

import azure.functions as func
from duo_hmac.duo_hmac import DuoHmac

from duo_proxy_core import duo_path_for, ensure_https, filter_params, normalize_next_offset

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)

_DUO_REQUEST_TIMEOUT_SECONDS = 60


def _duo_credentials() -> tuple[str, str, str]:
    """Read Duo credentials from the environment, failing loudly if misconfigured."""
    try:
        return os.environ["DUO_IKEY"], os.environ["DUO_SKEY"], os.environ["DUO_API_HOST"]
    except KeyError as missing:  # pragma: no cover - configuration error
        raise RuntimeError(f"Required app setting {missing} is not configured") from missing


@app.route(route="duo/{logtype}", methods=[func.HttpMethod.GET])
def duo_logs(req: func.HttpRequest) -> func.HttpResponse:
    logtype = req.route_params.get("logtype")
    mapping = duo_path_for(logtype)
    if mapping is None:
        return func.HttpResponse(
            json.dumps({"stat": "FAIL", "message": f"Unknown log type '{logtype}'"}),
            status_code=404,
            mimetype="application/json",
        )

    duo_path, _events_key = mapping

    try:
        params = filter_params(dict(req.params))  # mintime, maxtime, limit, next_offset, sort, ...
        ikey, skey, host = _duo_credentials()
        url, _body, headers = DuoHmac(ikey, skey, host).get_authentication_components(
            "GET", duo_path, params, {}
        )

        logging.info("Forwarding signed Duo request: %s params=%s", duo_path, sorted(params))
        with urllib.request.urlopen(
            urllib.request.Request(ensure_https(url), headers=headers),
            timeout=_DUO_REQUEST_TIMEOUT_SECONDS,
        ) as resp:
            payload = json.loads(resp.read())
            status = resp.status
    except urllib.error.HTTPError as exc:
        # Pass Duo's status (notably 429 + Retry-After) straight back so CCF can back off/retry.
        body = exc.read()
        passthrough_headers = {}
        retry_after = exc.headers.get("Retry-After") if exc.headers else None
        if retry_after:
            passthrough_headers["Retry-After"] = retry_after
        logging.warning("Duo returned HTTP %s for %s", exc.code, duo_path)
        return func.HttpResponse(
            body, status_code=exc.code, mimetype="application/json", headers=passthrough_headers
        )
    except urllib.error.URLError as exc:  # network/DNS/timeout
        logging.error("Failed to reach Duo at %s: %s", host, exc)
        return func.HttpResponse(
            json.dumps({"stat": "FAIL", "message": f"Upstream Duo request failed: {exc.reason}"}),
            status_code=502,
            mimetype="application/json",
        )
    except Exception as exc:  # noqa: BLE001 - last resort: surface config/signing errors as JSON
        logging.exception("Unhandled error while signing/forwarding the Duo request")
        return func.HttpResponse(
            json.dumps({"stat": "FAIL", "error": type(exc).__name__, "message": str(exc)}),
            status_code=500,
            mimetype="application/json",
        )

    return func.HttpResponse(
        json.dumps(normalize_next_offset(payload)),
        status_code=status,
        mimetype="application/json",
    )
