# Duo Security v2 Logs → Microsoft Sentinel (Codeless Connector Framework)

Three Microsoft Sentinel data connectors that ingest **Cisco Duo Admin API v2 log streams** —
**authentication**, **activity**, and **telephony** — using the **Codeless Connector Framework
(CCF / `RestApiPoller`)** with Microsoft's built‑in **`CiscoDuo`** authentication type, which performs
Duo's per‑request HMAC‑SHA1 signing inside the polling engine. The connectors call Duo **directly** — no
signing proxy, Azure Function, or Key Vault.

Beyond ingestion it is a **complete solution**: a backward‑compatible `CiscoDuo` parser (dual‑run with
the legacy table), 11 analytic rules + 10 hunting queries, a workbook, ASIM Authentication normalization,
and an administrator [migration runbook](deploy/migration-runbook.md) for replacing the legacy
HTTP‑Data‑Collector connector before that API retires (**2026‑09‑14**).

## Native Duo authentication (no proxy)

Duo's Admin API authenticates **every request** with an HMAC‑SHA1 signature:

```
Date: <RFC 2822>
Authorization: Basic base64( ikey : HMAC_SHA1( canonical_request, skey ) )
```

The signature covers the HTTP method, host, path, and the **lexicographically‑sorted query
parameters** — which change on every call because of `mintime` / `maxtime` / `next_offset` — so it must
be computed *dynamically, per request*.

CCF's `RestApiPoller` historically supported only Basic / APIKey / OAuth2 / JWT auth, none of which can
compute a dynamic HMAC — so earlier versions of this connector shipped a small **signing‑proxy Azure
Function**. **Microsoft has since added a built‑in `CiscoDuo` CCF auth type** that performs the HMAC
signing in the polling engine, so the connector now calls Duo directly and the proxy is gone.

> ⚠️ The `CiscoDuo` auth type is currently **preview** and not yet in the public CCF connection‑rules
> reference. It ships in Microsoft's own
> [Cisco Duo connectors](https://github.com/Azure/Azure-Sentinel/tree/master/Solutions/CiscoDuoSecurity).

| Duo API concern | Handled by |
| --- | --- |
| HMAC‑SHA1 request signing | **Built‑in `auth.type: CiscoDuo`** (Integration Key + Secret Key) |
| Epoch‑millisecond `mintime`/`maxtime` window | CCF `queryTimeFormat: UnixTimestampInMills` |
| `metadata.next_offset` cursor (incl. the auth‑log `[ts, txid]` array) | CCF `paging.pagingType: NextPageToken` |
| Response parsing, schema, transform, table | CCF DCR + custom `_CL` tables |
| Connector UI + Content Hub packaging | CCF `dataConnectorDefinition` (one per endpoint) |

## Architecture

```
 Microsoft Sentinel  (CCF RestApiPoller — built-in CiscoDuo auth)        Cisco Duo Admin API
 ┌────────────────────────────────────────────────────────────┐
 │ auth / activity / telephony connector (1 each)             │   HMAC-signed GET    ┌──────────────┐
 │   auth.type: CiscoDuo  → HMAC-SHA1 signing in the engine   │ ───────────────────► │  /admin/v2/  │
 │   mintime/maxtime  → UnixTimestampInMills                  │ ◄─────────────────── │  logs/<type> │
 │   next_offset      → NextPageToken                         │         JSON         └──────────────┘
 │   eventsJsonPaths  → DCR transformKql                      │
 │   → DuoSecurity{Authentication,Activity,Telephony}_CL      │   ikey / host / skey entered on each
 └────────────────────────────────────────────────────────────┘   connector page at Connect (encrypted)
```

Each endpoint is its own CCF connector (definition + poller + DCR + table). The Duo Integration Key, API
host, and Secret Key are entered on the connector page and the platform performs the signing — no request
ever leaves the Microsoft‑managed polling engine before it is signed.

## Repository layout

```
solution/                      Codeless CCF artifacts (Content-Hub packageable)
  Data Connectors/
    DuoSecurityAuth_CCF/         Authentication connector  (DuoSecurityAuthentication_CL)
    DuoSecurityActivity_CCF/     Activity connector        (DuoSecurityActivity_CL)
    DuoSecurityTelephony_CCF/    Telephony connector       (DuoSecurityTelephony_CL)
      each folder:  *_ConnectorDefinition.json  Connect UI (Duo host / ikey / skey)
                    *_PollingConfig.json        RestApiPoller, auth.type CiscoDuo, direct Duo endpoint
                    *_DCR.json                  single stream + transform
                    *_Table.json                custom *_CL table
  Parsers/CiscoDuo.yaml                         Backward-compat parser (new tables + legacy CiscoDuo_CL)
  Parsers/ASim/{vim,ASim}AuthenticationDuoSecurity.yaml   ASIM Authentication normalization
  Analytic Rules/*.yaml                         10 detections + a connector data-ingestion-stopped rule
  Hunting Queries/*.yaml                         10 hunting queries
  Workbooks/CiscoDuo.json                       Cisco Duo overview workbook
  Data/Solution_DuoSecurityCCF.json             V3 packaging input (lists all of the above)
  SolutionMetadata.json
  ReleaseNotes.md
deploy/                        deploy-ingestion.sh · deploy-connector.sh · enable-connector.md
                               operations.md (hardening) · migration-runbook.md (legacy → CCF)
                               build-package.sh (in-repo deployable mainTemplate) · stage-for-packaging.sh (→ V3)
                               reset-test-env.sh (guarded teardown) · test-package-deployment.sh
                                 (one-command from-scratch deploy + per-stage verify)
tests/                         sample v2 payloads + connector-config unit tests
```

## Streams

| Stream | Duo endpoint | Events path | `next_offset` | Table |
| --- | --- | --- | --- | --- |
| Authentication | `/admin/v2/logs/authentication` | `$.response.authlogs` | array `[ts, txid]` (handled natively) | `DuoSecurityAuthentication_CL` |
| Activity | `/admin/v2/logs/activity` | `$.response.items` | string | `DuoSecurityActivity_CL` |
| Telephony | `/admin/v2/logs/telephony` | `$.response.items` | string | `DuoSecurityTelephony_CL` |

*Additional Duo log streams — e.g. **Single Sign-On** (`/admin/v2/logs/sso`) — follow the exact same
pattern. See [adding a new log endpoint](deploy/adding-log-endpoints.md) to add one.*

### Querying note

Table columns are **lowercase snake_case**, mirroring Duo's v2 JSON keys (`result`, `event_type`,
`access_device`, `txid`, `telephony_type`, …); nested objects are `dynamic` and queried by JSON path
(e.g. `tostring(access_device.ip)`, `tostring(actor.name)`, `tostring(action.name)`). `TimeGenerated`
is derived from each event's `isotimestamp` / `ts` by the DCR transform. (The Azure CLI `-o table`
renderer title-cases column *headers* for display only — the stored names are lowercase, as
`getschema` confirms.)

## Deploy

Two scripted stages (full walkthrough + packaging in [`deploy/enable-connector.md`](deploy/enable-connector.md)):

1. **Ingestion** — `deploy/deploy-ingestion.sh` (DCE + 3 tables + DCR; prints the DCE URL + DCR immutable id).
2. **Connectors** — `deploy/deploy-connector.sh` (3 definitions + 3 pollers, built‑in CiscoDuo auth), **or**
   build a solution package: `deploy/build-package.sh` → a self‑contained deployable `mainTemplate.json`
   (in‑repo, no clone), or `deploy/stage-for-packaging.sh` → the official Content Hub package via the V3 tool.

Enter the Duo **API host / integration key / secret key** on each connector page and click **Connect**
(the scripted deploy wires them for you; the package collects them at Connect time). One command end to
end: `deploy/test-package-deployment.sh --duo-host … --ikey … --skey …`.

## Documentation

| Guide | For |
| --- | --- |
| [deploy/enable-connector.md](deploy/enable-connector.md) | Full deploy walkthrough (ingestion → connect), packaging, and end-to-end verification |
| [deploy/migration-runbook.md](deploy/migration-runbook.md) | **Administrators:** migrating off the legacy HTTP-Data-Collector connector — dual-run → cutover before 2026-09-14 |
| [deploy/operations.md](deploy/operations.md) | Production hardening: data completeness, credential rotation, multi-account, rate limits |
| [deploy/adding-log-endpoints.md](deploy/adding-log-endpoints.md) | **Maintainers:** add a new Duo log endpoint as an additional connector |
| [solution/Parsers/ASim/README.md](solution/Parsers/ASim/README.md) | ASIM Authentication parsers — conformance + unified-view inclusion |
| [solution/ReleaseNotes.md](solution/ReleaseNotes.md) | Version history + per-detection status (which rules fire / are mapped / are pending) |

## Test

See [`tests/`](tests/). `python -m pytest tests/` validates the connector configs (auth type, direct Duo
endpoints, stream/table consistency); the local/end-to-end steps are in `deploy/enable-connector.md`.

## Security notes

- The Duo **secret key (`skey`) is entered on the connector page at Connect time** and stored encrypted by
  the Microsoft Sentinel CCF platform — it is **not** placed in a Key Vault, an Azure Function, or the ARM
  deployment parameters. The solution package contains no secrets.
- Authentication to Duo uses the built‑in **`CiscoDuo`** auth type (HMAC‑SHA1 signing in the polling
  engine); the connector calls the Duo Admin API directly over TLS.
- Model is **one connector set per Duo account** — each connector's Connect holds its own ikey / host /
  skey. Deploy the solution once per Duo tenant you ingest from.
