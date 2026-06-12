# Maintenance: adding a new Duo log endpoint

Each Duo Admin API v2 log endpoint is its own self-contained CCF connector. Adding a new one — e.g.
**Single Sign-On (SSO)** (`/admin/v2/logs/sso`), or any future Duo log stream — is a mechanical, additive
change that follows the exact pattern of the three existing connectors. Nothing in the parser, rules, or
existing connectors needs to change unless you want the new stream to feed them.

This guide uses **SSO** as the worked example. Substitute your endpoint's names throughout.

## Naming conventions (pick these first)

For an endpoint with short name `<Name>` (e.g. `SSO`) and Duo path `/admin/v2/logs/<type>` (or
`/admin/v2/<path>`):

| Thing | Convention | SSO example |
| --- | --- | --- |
| Connector folder | `solution/Data Connectors/DuoSecurity<Name>_CCF/` | `DuoSecuritySSO_CCF/` |
| File prefix | `DuoSecurity<Name>` | `DuoSecuritySSO` |
| Table | `DuoSecurity<Name>_CL` | `DuoSecuritySSO_CL` |
| DCR stream | `Custom-DuoSecurity<Name>_CL` | `Custom-DuoSecuritySSO_CL` |
| Definition id | `DuoSecurity<Name>ConnectorDefinition` | `DuoSecuritySSOConnectorDefinition` |
| Poller name | `DuoSecurity<Name>Connector` | `DuoSecuritySSOConnector` |

## What to learn from the Duo API docs first

From the endpoint's [Duo Admin API](https://duo.com/docs/adminapi) reference, determine four things:

1. **API path** — e.g. `/admin/v2/logs/sso`.
2. **Events array JSON path** — where the records live in the response (auth uses `$.response.authlogs`;
   activity, telephony, and the other `/admin/v2/logs/<type>` endpoints use `$.response.items`).
3. **Pagination** — Duo v2 log endpoints page with `$.response.metadata.next_offset` (the native `CiscoDuo`
   auth type + CCF `NextPageToken` handle both the string and the auth-log `[ts, txid]` array forms). Reuse
   the existing `paging` block verbatim.
4. **Timestamp + fields** — which field carries the event time (for `TimeGenerated`) and the top-level
   fields/types for the table schema. Most v2 logs carry `ts` (epoch) and/or `isotimestamp`. Capture a real
   response (the `tests/sample_*_v2.json` files show the shape for the existing endpoints).

## Step 1 — Create the connector folder (4 files)

Copy an existing folder as the template — **Activity** is the simplest (string `next_offset`,
`$.response.items`). Create `solution/Data Connectors/DuoSecurity<Name>_CCF/` with:

**`DuoSecurity<Name>_PollingConfig.json`** — one poller. Keep the `auth`, `paging`, and time fields
**verbatim**; change only the connector/stream names and the endpoint:

```jsonc
{
  "connectorDefinitionName": "DuoSecurity<Name>ConnectorDefinition",
  "dataType": "DuoSecurity<Name>_CL",
  "dcrConfig": { "streamName": "Custom-DuoSecurity<Name>_CL", "dataCollectionEndpoint": "{{dataCollectionEndpoint}}", "dataCollectionRuleImmutableId": "{{dataCollectionRuleImmutableId}}" },
  "auth": { "type": "CiscoDuo", "APIKey": "[[parameters('ikey')]", "ClientSecret": "[[parameters('skey')]" },   // copy verbatim
  "request": { "apiEndpoint": "{{BaseUrl}}/admin/v2/logs/sso", "httpMethod": "GET", "queryTimeFormat": "UnixTimestampInMills", "startTimeAttributeName": "mintime", "endTimeAttributeName": "maxtime", /* ...copy the rest... */ },
  "paging": { "pagingType": "NextPageToken", "nextPageTokenJsonPath": "$.response.metadata.next_offset", "nextPageParaName": "next_offset", "pageSizeParaName": "limit", "pageSize": 1000 },   // copy verbatim
  "response": { "eventsJsonPaths": ["$.response.items"], "format": "json", "successStatusJsonPath": "$.stat", "successStatusValue": "OK" }
}
```

> The `auth` block, `{{BaseUrl}}` host token, and `[[parameters('ikey')]` / `[[parameters('skey')]` literals
> are what make the native **CiscoDuo** auth type sign the request in the polling engine — copy them exactly.

**`DuoSecurity<Name>_ConnectorDefinition.json`** — the Connect UI. Copy an existing one; change `id`,
`title`, `graphQueriesTableName` (→ your table), the sample queries, and the description. Keep the
`instructionSteps` (the `BaseUrl` / `ikey` / `skey` textboxes + `ConnectionToggleButton`) **verbatim**.

**`DuoSecurity<Name>_DCR.json`** — one stream. Set the `streamDeclarations` key + `outputStream` to
`Custom-DuoSecurity<Name>_CL`, list the columns (lowercase Duo keys), and write a `transformKql` that derives
`TimeGenerated` from the event's timestamp field, e.g. `source | extend TimeGenerated = todatetime(ts)` (use
`isotimestamp`, or an `iif(...)`, as appropriate). Keep `kind: Direct` and the `destinations` block.

**`DuoSecurity<Name>_Table.json`** — the `DuoSecurity<Name>_CL` table: `TimeGenerated` (datetime) + the same
columns as the DCR stream. Use `dynamic` for nested objects, `string`/`long`/`int`/`real` for scalars.

## Step 2 — Register it (4 small edits)

1. **Assembler** — add a tuple to `CONNECTORS` in [`deploy/_build_maintemplate.py`](_build_maintemplate.py):
   ```python
   {"key": "sso", "folder": "DuoSecuritySSO_CCF", "prefix": "DuoSecuritySSO"},
   ```
2. **Scripted renderer** — add a tuple to `CONNECTORS` in
   [`deploy/_render_connector_bodies.py`](_render_connector_bodies.py):
   ```python
   ("DuoSecuritySSO_CCF", "DuoSecuritySSO"),
   ```
3. **Scripted ingestion** — in [`deploy/ingestion-template.json`](ingestion-template.json) (the shared
   multi-stream DCR used by the scripted/test deploy) add: the new **table** resource, a
   **`streamDeclarations`** entry, and a **`dataFlows`** entry for `Custom-DuoSecurity<Name>_CL`. (The package
   ships one DCR per connector; this file is the scripted-path equivalent.)
4. **Solution manifest** — add the definition path to `"Data Connectors"` in
   [`solution/Data/Solution_DuoSecurityCCF.json`](../solution/Data/Solution_DuoSecurityCCF.json):
   ```json
   "Data Connectors/DuoSecuritySSO_CCF/DuoSecuritySSO_ConnectorDefinition.json"
   ```

## Step 3 — Add a test

Add a tuple to `CONNECTORS` in [`tests/test_connector_config.py`](../tests/test_connector_config.py) so the
new connector is validated for native auth, direct endpoint, and stream/table consistency:

```python
("DuoSecuritySSO_CCF", "DuoSecuritySSO", "DuoSecuritySSO_CL", "sso", "$.response.items"),
```
(The 4th element is the path suffix after `/admin/v2/logs/`; for a non-`/logs/` endpoint, relax the
`apiEndpoint` assertion in the test accordingly.)

## Step 4 — (Optional) wire it into the parser / content

The new table is queryable immediately. To surface it through the unified `CiscoDuo` parser (and thus the
existing rules/hunts/workbook), add a `union` branch in
[`solution/Parsers/CiscoDuo.yaml`](../solution/Parsers/CiscoDuo.yaml) that projects the new table to the
shared alias schema (`EventVendor`, `EventProduct`, `EventType`, `SrcIpAddr`, …), seeded with an empty
`datatable` like the other branches. Add analytic rules / hunting queries / workbook tiles only if the new
stream warrants detections.

## Step 5 — Build, test, deploy

```bash
python -m pytest tests/            # the new connector is validated
deploy/build-package.sh            # → solution/Package/mainTemplate.json now has 4 connectors
# deploy + Connect as usual (deploy/enable-connector.md); verify the new table populates and paginates.
```

`build-package.sh` and `deploy-connector.sh` pick the new connector up automatically from the `CONNECTORS`
lists — no other code changes. Verify end to end per [`enable-connector.md`](enable-connector.md): the new
connector page Connects, `DuoSecurity<Name>_CL` populates, and >1000 events in a window all ingest.

## Checklist

- [ ] `solution/Data Connectors/DuoSecurity<Name>_CCF/` with the 4 files (definition, pollingconfig, DCR, table)
- [ ] `auth.type: CiscoDuo` + `[[parameters('ikey')]` / `[[parameters('skey')]` copied verbatim
- [ ] `apiEndpoint` = `{{BaseUrl}}/admin/v2/logs/...`; `eventsJsonPaths` correct; `paging` block copied verbatim
- [ ] DCR stream / `outputStream` / table all named `…DuoSecurity<Name>_CL`; `transformKql` sets `TimeGenerated`
- [ ] `CONNECTORS` updated in `_build_maintemplate.py`, `_render_connector_bodies.py`, `tests/test_connector_config.py`
- [ ] table + stream + dataFlow added to `ingestion-template.json`
- [ ] definition path added to `Solution_DuoSecurityCCF.json`
- [ ] (optional) `CiscoDuo.yaml` branch + content
- [ ] `pytest` green, `build-package.sh` shows the new connector, deploy + Connect + data verified
