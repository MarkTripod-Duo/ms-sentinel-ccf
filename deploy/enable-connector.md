# Deploy & enable the Duo CCF connectors

Two stages: **(1)** create the ingestion resources (DCE, tables, DCR), **(2)** deploy the three connectors
and connect them. Authentication uses Microsoft's built‑in **`CiscoDuo`** auth type — the pollers call Duo
directly, so there is **no signing proxy** to stand up.

**Prerequisite — Duo Admin API application.** In the [Duo Admin Panel](https://admin.duosecurity.com),
protect an **Admin API** application with the **Grant read log** permission, and note its **API hostname**
(`api-XXXXXXXX.duosecurity.com`), **Integration Key** (`ikey`), and **Secret Key** (`skey`).

---

## Stage 1 — Ingestion resources (DCE + tables + DCR)

The connectors need a **Data Collection Endpoint** URL and the **DCR immutable id**.

**Scripted (recommended):** creates the DCE, the three tables, and the DCR in one shot and prints both:

```bash
deploy/deploy-ingestion.sh \
  --resource-group rg-sentinel-duo-test \
  --workspace      law-sentinel-duo-test \
  --location       eastus
```

It deploys [`deploy/ingestion-template.json`](ingestion-template.json) (the same table + DCR schemas as the
`solution/` source, combined as one multi-stream DCR for the scripted deploy). Continue to Stage 2 with the
printed `DCE_URL` / `DCR immutable id`.

**By hand (alternative):** create the DCE, the three tables (columns in each
`solution/Data Connectors/DuoSecurity*_CCF/*_Table.json`), and the DCR(s) (from each `*_DCR.json`,
substituting `{{workspaceResourceId}}` and `{{dataCollectionEndpointId}}`):

```bash
az monitor data-collection endpoint create -g <rg> -n duo-ccf-dce -l <location> --public-network-access Enabled
DCE_URL=$(az monitor data-collection endpoint show -g <rg> -n duo-ccf-dce --query logsIngestion.endpoint -o tsv)
# ...create the 3 tables + DCR(s), then:
DCR_IMMUTABLE_ID=$(az monitor data-collection rule show -g <rg> -n duo-ccf-dcr --query immutableId -o tsv)
```

> Each poller `streamName` (`Custom-DuoSecurityAuthentication_CL`, `…Activity_CL`, `…Telephony_CL`) must
> match its DCR `streamDeclarations` exactly — they already do in the source files.

---

## Stage 2, Path 0 — Scripted direct deploy (fastest for testing)

Renders the three connector definitions + pollers from the `solution/` source — resolving the built‑in
`CiscoDuo` auth block with your Duo credentials so the pollers are **active on deploy** — and PUTs them with
`az rest`:

```bash
deploy/deploy-connector.sh \
  --resource-group   rg-sentinel-duo-test \
  --workspace        law-sentinel-duo-test \
  --duo-host         https://api-XXXXXXXX.duosecurity.com \
  --ikey             DIXXXXXXXXXXXXXXXXXX \
  --skey             '<duo-secret-key>' \
  --dce              "<DCE_URL from Stage 1>" \
  --dcr-immutable-id "<dcr-... from Stage 1>"
```

Good for a working test environment. For a publishable/shareable artifact, use Path A.

## Stage 2, Path A — Build a solution package (recommended for distribution)

Both packaging paths are prepared in‑repo.

**A1 — Self-contained deployable package** (no Azure‑Sentinel clone, no PowerShell):

```bash
deploy/build-package.sh    # → solution/Package/{mainTemplate.json, createUiDefinition.json, .zip}
```

Assembles the whole Sentinel‑side solution (shared DCE + 3 tables + 3 DCRs + 3 connector definitions + 3
pollers + parsers + 11 rules + 10 hunts + workbook) into one ARM template (validated with
`az deployment group validate`). Requires `python3 -m pip install pyyaml`. Then deploy and **Connect**:

```bash
az deployment group create -g <rg> --template-file solution/Package/mainTemplate.json \
  --parameters workspace=<ws> workspace-location=<region>
```

The package carries no secrets — after it deploys, open each Cisco Duo connector in **Microsoft Sentinel →
Data connectors**, enter the **API host / integration key / secret key**, and click **Connect**.

> **Test it end-to-end in one command.** `deploy/test-package-deployment.sh` runs the whole path from
> scratch — creates the workspace, deploys ingestion + the three connectors (built‑in CiscoDuo auth, active
> pollers), builds + ARM‑validates the package, and verifies (active pollers, no Function App/Key Vault, data
> snapshot) with per‑stage PASS/FAIL. Preview with `--dry-run`; pair with `deploy/reset-test-env.sh`:
> ```bash
> deploy/reset-test-env.sh --yes
> deploy/test-package-deployment.sh --duo-host https://api-XXXX.duosecurity.com --ikey DI... --skey '<skey>' \
>   --wait-for-data 15
> ```

**A2 — Official Content Hub package** (marketplace / Partner Center):

```bash
deploy/stage-for-packaging.sh --sentinel-repo ~/code/Azure-Sentinel
# then run the V3 tool in the clone (the script prints the exact command + data-folder path)
```

Stages `solution/` into the clone and runs the [V3 tool](https://github.com/Azure/Azure-Sentinel/blob/master/Tools/Create-Azure-Sentinel-Solution/V3/CCP_README.md),
which emits the official `Package/` with the Content Hub `contentPackages`/metadata. Set real
`publisherId`/`Author`/`offerId` first.

## Stage 2, Path B — Wire the ARM resources by hand

Deploy each connector's definition and poller directly. In the poller, the credentials are escaped template
literals that Microsoft Sentinel resolves when you click **Connect** on the connector page:

| Token | Value |
| --- | --- |
| `{{BaseUrl}}` (in `apiEndpoint`) → `[parameters('BaseUrl')]` | Duo API host, entered at Connect |
| `[[parameters('ikey')]` / `[[parameters('skey')]` (in `auth`) | Duo ikey / skey, entered at Connect |
| `{{dataCollectionEndpoint}}` | Stage 1 `DCE_URL` |
| `{{dataCollectionRuleImmutableId}}` | Stage 1 `DCR_IMMUTABLE_ID` |

For each of `DuoSecurityAuth_CCF` / `DuoSecurityActivity_CCF` / `DuoSecurityTelephony_CCF`:
1. `PUT` the `dataConnectorDefinitions/<id>` resource (from `*_ConnectorDefinition.json`).
2. `PUT` the `dataConnectors/<name>` poller (from `*_PollingConfig.json`).
3. On the connector page, enter the Duo host / ikey / skey and **Connect** (or set them in the body for an
   active deploy, as `deploy-connector.sh` does).

---

## Verify (end-to-end)

1. **Connector pages**: each Cisco Duo connector shows **Connected** and, after a poll cycle (~5 min),
   "data received".
2. **Tables**: in Logs, run each and confirm rows + a sane `TimeGenerated`:
   ```kusto
   DuoSecurityAuthentication_CL | take 10
   DuoSecurityActivity_CL       | take 10
   DuoSecurityTelephony_CL      | take 10
   ```
3. **Parser + content**: `CiscoDuo | summarize count() by EventType` shows all three streams;
   `ASimAuthenticationDuoSecurity | take 5` resolves.
4. **Pagination**: generate >1000 auth events in a window and confirm all are ingested — proves the
   `next_offset` cursor (the auth‑log `[ts, txid]` array) round‑trips through the native `CiscoDuo` auth type.
5. **Proxy‑free**: the resource group contains a DCE, tables, DCR(s), connectors, and content — **no**
   Function App, plan, storage, or Key Vault.

## Operational notes

Production hardening — the trailing‑edge data‑completeness gap, credential rotation, multiple Duo accounts,
and rate limits — is in [`operations.md`](operations.md).
