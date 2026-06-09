# Duo Security v2 Logs → Microsoft Sentinel (Codeless Connector Framework)

A Microsoft Sentinel data connector that ingests **Cisco Duo Admin API v2 log streams** —
**authentication**, **activity**, and **telephony** — using the **Codeless Connector Framework
(CCF / `RestApiPoller`)**, plus a tiny stateless **signing proxy** that bridges the one thing CCF
cannot do natively: Duo's per-request HMAC‑SHA1 request signing.

## Why a signing proxy is required

Duo's Admin API authenticates **every request** with an HMAC‑SHA1 signature:

```
Date: <RFC 2822>
Authorization: Basic base64( ikey : HMAC_SHA1( canonical_request, skey ) )
```

The signature covers the HTTP method, host, path, and the **lexicographically‑sorted query
parameters** — which change on every call because of `mintime` / `maxtime` / `next_offset`. So the
signature must be computed *dynamically, per request*.

CCF's `RestApiPoller` supports only **Basic, APIKey, OAuth2, and JWT** auth
([Microsoft connection-rules reference](https://learn.microsoft.com/en-us/azure/sentinel/data-connector-connection-rules-reference)).
None of them can compute a dynamic HMAC. **A fully-codeless connector against Duo's native API is
therefore impossible.**

This project keeps ~90% of the connector codeless and isolates the unavoidable signing into a
~30‑line Azure Function that uses the pure‑Python [`duo-hmac`](https://pypi.org/project/duo-hmac/)
library. Everything else maps cleanly onto CCF:

| Duo API concern | Handled by |
| --- | --- |
| HMAC‑SHA1 request signing | **Signing proxy** (`signing-proxy/`) |
| Epoch‑millisecond `mintime`/`maxtime` time window | CCF `queryTimeFormat: UnixTimestampInMills` |
| `metadata.next_offset` cursor pagination | CCF `paging.pagingType: NextPageToken` |
| Response parsing, schema, transform, table | CCF DCR + custom `_CL` tables |
| Connector UI + Content Hub packaging | CCF `dataConnectorDefinition` |

## Architecture

```
 Microsoft Sentinel  (CCF RestApiPoller — codeless)        Signing proxy            Cisco Duo
 ┌──────────────────────────────────────────────┐        (Azure Function)          Admin API
 │ auth / activity / telephony poller (1 each)   │         duo-hmac, stateless
 │  mintime/maxtime  → UnixTimestampInMills       │  GET   ┌───────────────┐  HMAC  ┌──────────────┐
 │  next_offset      → NextPageToken    ──────────┼───────►│ sign + forward├───────►│ /admin/v2/   │
 │  eventsJsonPaths  → DCR transformKql           │◄───────┤ (normalize    │◄───────┤  logs/<type> │
 │  → DuoSecurity{Authentication,Activity,        │  JSON  │  next_offset) │  JSON  └──────────────┘
 │     Telephony}_CL                              │        └───────────────┘
 └──────────────────────────────────────────────┘         x-functions-key      ikey/skey in Key Vault
```

The proxy is a **dumb pass-through signer**: it reconstructs the intended Duo request from the
inbound query string, signs it with `duo-hmac`, issues the call, and returns Duo's body verbatim —
with a single normalization (the authentication-log `next_offset` array → comma string) so CCF's
`NextPageToken` cursor round-trips. All time-windowing and pagination logic stays in CCF.

## Repository layout

```
solution/                      Codeless CCF artifacts (Content-Hub packageable)
  Data Connectors/DuoSecurityCCF_ccp/
    DuoSecurity_DataConnectorDefinition.json    Connector UI (collects proxy URL + function key)
    DuoSecurity_PollingConfig.json              3 RestApiPoller connections (one array, one per stream)
    DuoSecurity_DCR.json                        3 streams + 3 transforms
    DuoSecurity_Tables.json                     3 custom *_CL tables
  Parsers/CiscoDuo.yaml                         Backward-compat parser (new tables + legacy CiscoDuo_CL)
  Parsers/ASim/{vim,ASim}AuthenticationDuoSecurity.yaml   ASIM Authentication normalization
  Analytic Rules/*.yaml                         10 detections + a connector data-ingestion-stopped rule
  Hunting Queries/*.yaml                        10 hunting queries
  Workbooks/CiscoDuo.json                       Cisco Duo overview workbook
  Data/Solution_DuoSecurityCCF.json             V3 packaging input (lists all of the above)
  SolutionMetadata.json
  ReleaseNotes.md
signing-proxy/                 The thin HMAC signer (Azure Function, Python)
  function_app.py  requirements.txt  host.json  local.settings.json.sample  azuredeploy.json  README.md
deploy/                        deploy-proxy.sh · deploy-ingestion.sh · deploy-connector.sh · enable-connector.md
                               operations.md (hardening) · migration-runbook.md (legacy → CCF)
tests/                         sample v2 payloads + unit tests for the proxy
```

## Streams

| Stream | Duo endpoint | Events path | `next_offset` | Table |
| --- | --- | --- | --- | --- |
| Authentication | `/admin/v2/logs/authentication` | `$.response.authlogs` | array `[ts, txid]` → string | `DuoSecurityAuthentication_CL` |
| Activity | `/admin/v2/logs/activity` | `$.response.items` | string | `DuoSecurityActivity_CL` |
| Telephony | `/admin/v2/logs/telephony` | `$.response.items` | string | `DuoSecurityTelephony_CL` |

*Trust Monitor (`/admin/v2/trust_monitor/events`) is intentionally deferred — it follows the exact
same pattern; add a 4th route/poller/table to enable it.*

### Querying note

Table columns are **lowercase snake_case**, mirroring Duo's v2 JSON keys (`result`, `event_type`,
`access_device`, `txid`, `telephony_type`, …); nested objects are `dynamic` and queried by JSON path
(e.g. `tostring(access_device.ip)`, `tostring(actor.name)`, `tostring(action.name)`). `TimeGenerated`
is derived from each event's `isotimestamp` / `ts` by the DCR transform. (The Azure CLI `-o table`
renderer title-cases column *headers* for display only — the stored names are lowercase, as
`getschema` confirms.)

## Deploy (summary — see [`deploy/enable-connector.md`](deploy/enable-connector.md))

1. **Signing proxy** — deploy `signing-proxy/azuredeploy.json`, push the function code, put the Duo
   `skey` in Key Vault, set `DUO_IKEY` / `DUO_API_HOST`. Capture the **Function URL** + **Function key**.
2. **Ingestion** — create a Data Collection Endpoint, the three tables, and the DCR from `solution/`.
   Capture the **DCE URL** + **DCR immutable id**.
3. **Connector** — deploy the connector definition + three pollers wired with the Function URL/key and
   DCE/DCR ids, *or* package `solution/` with the
   [Create-Azure-Sentinel-Solution V3 tool](https://github.com/Azure/Azure-Sentinel/blob/master/Tools/Create-Azure-Sentinel-Solution/V3/CCP_README.md)
   into a Content Hub solution and enter the Function URL/key in the connector pane.

## Test

See [`tests/`](tests/). `python -m pytest tests/` runs the proxy unit tests (mocked Duo); the
local/end-to-end steps are in `deploy/enable-connector.md`.

## Security notes

- The Duo **secret key (`skey`) never transits Sentinel** — it lives only in the proxy's Key Vault,
  read via the Function's managed identity. Sentinel only holds the proxy's Function key.
- The proxy authenticates inbound CCF calls with the Azure Functions **function key**
  (`x-functions-key`); it is not an open relay.
- Default model is **one Duo account per proxy** (ikey/host/skey in the Function's config). A
  multi-account variant (pass `ikey` per call, look up `skey` in Key Vault) is noted in
  [`signing-proxy/README.md`](signing-proxy/README.md).
```
