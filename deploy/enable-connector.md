# Deploy & enable the Duo CCF connector

Three stages: **(1)** stand up the signing proxy, **(2)** create the ingestion resources (DCE, tables,
DCR), **(3)** deploy the connector and connect it. Stage 3 has two paths — package it as a Content Hub
solution (recommended) or wire the ARM resources by hand.

---

## Stage 1 — Signing proxy

```bash
deploy/deploy-proxy.sh \
  --resource-group <rg> \
  --app-name       duo-ccf-proxy-<unique> \
  --duo-host       api-XXXXXXXX.duosecurity.com \
  --duo-ikey       DIXXXXXXXXXXXXXXXXXX \
  --duo-skey       <duo-secret-key>
```

The Duo API application needs the **Grant read log** permission. The script prints the two values
Stage 3 needs: **Signing proxy base URL** (`https://<app>.azurewebsites.net/api`) and **Function key**.
Smoke-test the printed `curl` before continuing — you should get `{"stat":"OK", ...}`.

---

## Stage 2 — Ingestion resources (DCE + tables + DCR)

The connector pollers need a **Data Collection Endpoint** URL and the **DCR immutable id**.

**Scripted (recommended):** creates the DCE, the three tables, and the DCR in one shot and prints
both values:

```bash
deploy/deploy-ingestion.sh \
  --resource-group rg-sentinel-duo-test \
  --workspace      law-sentinel-duo-test \
  --location       eastus
```

It deploys [`deploy/ingestion-template.json`](ingestion-template.json) (the same table + DCR schemas
as the `solution/` source). Skip to Stage 3 with the printed `DCE_URL` / `DCR immutable id`.

**By hand (alternative):** the `solution/...` JSON files use CCF `{{placeholders}}`; the V3 packaging
tool (Stage 3, Path A) fills them automatically. To create them manually, substitute the placeholders
and deploy:

```bash
WS=/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<workspace>

# 2a. Data Collection Endpoint
az monitor data-collection endpoint create -g <rg> -n duo-ccf-dce -l <location> --public-network-access Enabled
DCE_ID=$(az monitor data-collection endpoint show -g <rg> -n duo-ccf-dce --query id -o tsv)
DCE_URL=$(az monitor data-collection endpoint show -g <rg> -n duo-ccf-dce --query logsIngestion.endpoint -o tsv)

# 2b. Custom tables — deploy the 3 tables from DuoSecurity_Tables.json (one PUT per table), e.g.:
az monitor log-analytics workspace table create -g <rg> --workspace-name <workspace> \
   -n DuoSecurityAuthentication_CL --columns TimeGenerated=datetime access_device=dynamic alias=string \
   application=dynamic auth_device=dynamic email=string event_type=string factor=string isotimestamp=string \
   ood_software=string reason=string result=string timestamp=long trusted_endpoint_status=string txid=string user=dynamic
#  ...repeat for DuoSecurityActivity_CL and DuoSecurityTelephony_CL (see DuoSecurity_Tables.json for columns).

# 2c. DCR — substitute {{workspaceResourceId}} and {{dataCollectionEndpointId}} in DuoSecurity_DCR.json then:
az monitor data-collection rule create -g <rg> -n duo-ccf-dcr -l <location> --rule-file ./DuoSecurity_DCR.resolved.json
DCR_IMMUTABLE_ID=$(az monitor data-collection rule show -g <rg> -n duo-ccf-dcr --query immutableId -o tsv)
```

Record `DCE_URL` and `DCR_IMMUTABLE_ID`.

> The three poller `streamName`s (`Custom-DuoSecurityAuthentication_CL`, `…Activity_CL`, `…Telephony_CL`)
> must match the DCR `streamDeclarations` exactly — they already do in the source files.

---

## Stage 3, Path 0 — Scripted direct deploy (fastest for testing)

Renders the definition + three pollers from the `solution/` source (substituting the proxy/DCE/DCR
values) and PUTs them with `az rest`:

```bash
deploy/deploy-connector.sh \
  --resource-group   rg-sentinel-duo-test \
  --workspace        law-sentinel-duo-test \
  --proxy-url        "$PROXY_URL" \
  --function-key     "$PROXY_KEY" \
  --dce              "<DCE_URL from Stage 2>" \
  --dcr-immutable-id "<dcr-... from Stage 2>"
```

Good for a working test environment. For a publishable/shareable artifact, use Path A instead.

## Stage 3, Path A — Build a solution package (recommended for distribution)

Both packaging paths are prepared in-repo.

**A1 — Self-contained deployable package** (no Azure-Sentinel clone, no PowerShell):

```bash
deploy/build-package.sh    # → solution/Package/{mainTemplate.json, createUiDefinition.json, .zip}
```

Assembles the whole Sentinel-side solution (DCE + tables + DCR + connector definition + 3 pollers +
parsers + 11 rules + 10 hunts + workbook) into one ARM template (validated with
`az deployment group validate`). Requires `python3 -m pip install pyyaml`. Then deploy:

```bash
az deployment group create -g <rg> --template-file solution/Package/mainTemplate.json \
  --parameters workspace=<ws> proxyBaseUrl=https://<proxy>.azurewebsites.net/api functionKey=<key>
```

One-click deployable and portal "custom template"-loadable — but **not** the official Content Hub
gallery format.

**A2 — Official Content Hub package** (marketplace / Partner Center):

```bash
deploy/stage-for-packaging.sh --sentinel-repo ~/code/Azure-Sentinel
# then run the V3 tool in the clone (the script prints the exact command + data-folder path)
```

Stages `solution/` into the clone and runs the [V3 tool](https://github.com/Azure/Azure-Sentinel/blob/master/Tools/Create-Azure-Sentinel-Solution/V3/CCP_README.md),
which emits the official `Package/` with the Content Hub `contentPackages`/metadata. Set real
`publisherId`/`Author`/`offerId` first.

Either way, in **Microsoft Sentinel → Data connectors**, open **Cisco Duo Security v2 Logs (CCF)**,
enter the **proxy base URL** + **function key**, and click **Connect**.

> The single definition references three pollers (one file, array of three) and one DCR with three
> streams — the documented CCP "single definition / multiple pollers" layout.

## Stage 3, Path B — Wire the ARM resources by hand

Deploy the connector definition and the three pollers directly, substituting the placeholders with
the values from Stages 1–2:

| Placeholder | Value |
| --- | --- |
| `{{proxyBaseUrl}}` | Stage 1 proxy base URL |
| `{{functionKey}}` | Stage 1 function key |
| `{{dataCollectionEndpoint}}` | Stage 2 `DCE_URL` |
| `{{dataCollectionRuleImmutableId}}` | Stage 2 `DCR_IMMUTABLE_ID` |
| `{{location}}`, `{{workspace}}`, `{{workspaceResourceId}}` | your workspace details |

1. `PUT` the `dataConnectorDefinitions/DuoSecurityCCF` resource (from `DuoSecurity_DataConnectorDefinition.json`).
2. `PUT` each of the three `dataConnectors` pollers (from `DuoSecurity_PollingConfig.json`).
3. Confirm `isActive: true` and that each poller's `connectorDefinitionName` is `DuoSecurityCCF`.

---

## Verify (end-to-end)

1. **Proxy**: the Stage 1 `curl` returns `{"stat":"OK","response":{"authlogs":[...],"metadata":{...}}}`.
2. **Connector page**: shows **Connected** and, after a poll cycle (~5 min), "data received".
3. **Tables**: in Logs, run each and confirm rows + a sane `TimeGenerated`:
   ```kusto
   DuoSecurityAuthentication_CL | take 10
   DuoSecurityActivity_CL       | take 10
   DuoSecurityTelephony_CL      | take 10
   ```
4. **Pagination**: generate >1000 auth events in a window (or lower `pageSize`) and confirm all are
   ingested — proves the `next_offset` cursor round-trips through the proxy.

## Operational notes

- **Duo's ~2-minute availability delay**: events younger than ~2 min return empty and are picked up
  on a later poll cycle as the `mintime`/`maxtime` window advances. If you require a strict
  zero-gap guarantee at the trailing edge, switch the authentication poller to `PersistentToken`
  paging (Duo's `next_offset` is a durable cursor) or have the proxy clamp `maxtime` to `now-2min`.
- **Rate limits**: the proxy returns Duo `429` + `Retry-After` to CCF, which backs off and retries
  (`retryCount: 3`). Keep `rateLimitQPS` modest.
