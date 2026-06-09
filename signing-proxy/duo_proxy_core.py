"""Pure, dependency-free helpers for the Duo signing proxy.

Kept free of `azure.functions` and `duo_hmac` imports so the request/response shaping logic can be
unit-tested with the standard library alone (see ../tests/test_signing_proxy.py).
"""

from __future__ import annotations

# Proxy route segment -> (Duo Admin API v2 path, JSON key that holds the event list).
# The events key is consumed by the CCF connector's eventsJsonPaths, not by this proxy; it is kept
# here as the single source of truth for the three supported streams.
LOG_TYPES = {
    "authentication": ("/admin/v2/logs/authentication", "authlogs"),
    "activity": ("/admin/v2/logs/activity", "items"),
    "telephony": ("/admin/v2/logs/telephony", "items"),
}

# Query params that must never be forwarded to (and signed for) Duo. `code` is the Azure Functions
# key when supplied in the query string instead of the x-functions-key header.
CONTROL_PARAMS = frozenset({"code"})


def duo_path_for(logtype: str):
    """Return (duo_path, events_key) for a route segment, or None if unsupported."""
    return LOG_TYPES.get((logtype or "").lower())


def filter_params(params: dict) -> dict:
    """Drop control params so only genuine Duo query params are signed and forwarded."""
    return {k: v for k, v in params.items() if k not in CONTROL_PARAMS}


def normalize_next_offset(payload: dict) -> dict:
    """Flatten an authentication-log ``next_offset`` array into a comma-joined string in place.

    Duo's ``/admin/v2/logs/authentication`` returns ``response.metadata.next_offset`` as
    ``["<epoch_ms>", "<txid>"]``. CCF's NextPageToken pager extracts a single scalar and resends it
    as one query parameter, so the array is joined here. Activity/telephony already return a string
    and pass through untouched. Payloads without the nested metadata are returned unchanged.
    """
    metadata = payload.get("response", {}).get("metadata", {})
    offset = metadata.get("next_offset")
    if isinstance(offset, list):
        metadata["next_offset"] = ",".join(str(part) for part in offset)
    return payload


def ensure_https(url: str) -> str:
    """Prepend ``https://`` if missing.

    ``duo-hmac``'s ``get_authentication_components`` returns a scheme-less ``host/path?query``
    string; ``urllib.request.urlopen`` requires a scheme or it raises ``ValueError: unknown url
    type``. Idempotent for URLs that already carry a scheme.
    """
    if url.startswith(("http://", "https://")):
        return url
    return "https://" + url
