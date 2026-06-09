# Operations & production hardening

Operational guidance for running the Duo CCF connector + signing proxy in production.

## 1. Data completeness (the zero-gap consideration)

**The constraint.** Duo's Admin API has a deliberate **~2-minute availability delay** — events younger
than ~2 minutes are not yet returned. Microsoft Sentinel CCF uses **service-managed, time-based
checkpointing**: each poll's start time is the *last run time* (wall clock), advanced by the service
after the run; CCF **cannot persist a custom cursor** (`next_offset`) across runs, and `PersistentToken`
paging is not a reliable substitute (no production CCF connector uses it). The result: events that are
still inside Duo's 2-minute delay window when a poll runs fall *before* the next poll's start time and
are **skipped** — a recurring trailing-edge gap.

**The mitigation (opt-in).** The proxy can re-query a lookback overlap on every poll so those
delayed events are picked up on the next cycle:

```bash
az functionapp config appsettings set -g <rg> -n <proxy-app> \
  --settings DUO_MINTIME_LOOKBACK_SECONDS=180     # 0 = off (default); 180 covers the ~120s delay
```

(Or set `mintimeLookbackSeconds` when deploying `azuredeploy.json`.) The proxy subtracts this from the
incoming `mintime` before signing the Duo request — see `apply_mintime_lookback` in
[`duo_proxy_core.py`](../signing-proxy/duo_proxy_core.py).

**The trade-off — duplicates.** The overlap re-ingests events already seen (roughly `overlap / poll-interval`
of events), so **de-duplicate by `txid` at query time**. The duplicates are *not* baked out of the raw
table (DCR transforms can't dedup across batches) and dedup is intentionally *not* in the `CiscoDuo`
parser (it would slow every query). Dedup where it matters:

```kusto
// de-duplicated authentication events
DuoSecurityAuthentication_CL
| summarize arg_max(TimeGenerated, *) by txid
```

To keep the duplicate rate low, prefer a **larger `queryWindowInMin`** (e.g. 15-30) with a small overlap.

**Decision guide.** Leave the overlap **off** (default) if a rare trailing-edge gap is acceptable and you
monitor freshness with the *Cisco Duo - Data ingestion stopped* analytic rule. Turn it **on** when you
cannot afford to miss auth events and can dedup at query time.

## 2. Rotating the Duo secret key (skey)

The `skey` lives only in Key Vault; rotate it without redeploying:

```bash
KV=$(az keyvault list -g <rg> --query "[0].name" -o tsv)
# 1. Create the new skey in the Duo Admin Panel (it can coexist with the old one briefly).
# 2. Update the secret (a new version is created automatically):
az keyvault secret set --vault-name "$KV" -n DUO-SKEY --value '<new-skey>'
# 3. Recycle the proxy so it re-reads the Key Vault reference:
az functionapp restart -g <rg> -n <proxy-app>
# 4. Smoke-test, then delete the old skey in Duo.
```

Rotate `ikey`/host the same way via the `DUO_IKEY` / `DUO_API_HOST` app settings (+ restart). Set a
calendar reminder; Duo does not expire keys automatically.

## 3. Multiple Duo accounts behind one proxy (optional)

The default is **one proxy per Duo account** (ikey/host/skey in the Function config) — simplest and most
isolated. To serve several Duo accounts from a single proxy:

- Have the CCF connector send `ikey` (and optionally `host`) as query parameters; collect them as extra
  Textboxes in the connector definition and add them to each poller's `queryParameters`.
- Store one secret per account in Key Vault, e.g. `DUO-SKEY-<ikey>`, and have the proxy look it up at
  runtime with its managed identity (add `azure-identity` + `azure-keyvault-secrets` to
  `requirements.txt`; cache the `SecretClient` and secret values per ikey).
- Strip `ikey`/`host` from the params before signing (add them to `CONTROL_PARAMS`) so they are not sent
  to Duo, then pass them into `DuoHmac(ikey, skey, host)`.

This trades the platform-resolved Key Vault reference for a small runtime KV dependency. Keep one DCE/DCR
per workspace; the `addOnAttributes`/a tenant column can distinguish accounts. (Not implemented here —
ask if you want it built and tested.)

## 4. Networking, scaling & throttling

- **Rate limits.** Duo returns `429` with `Retry-After`; the proxy passes both straight back and CCF
  honors them (`retryCount: 3`). Keep `rateLimitQPS` modest (2) and consider
  `request.rateLimitConfig` (`OnlyWhen429` + `useResetOrRetryAfterHeaders`) for adaptive backoff under load.
- **One connection per stream.** Run a single CCF connection per log type to avoid racing the shared
  time checkpoint. Multiple parallel connections against the same stream can double-ingest or interleave.
- **Private networking.** For a locked-down deployment, put the Function on a VNet (Elastic Premium plan)
  with outbound access to `*.duosecurity.com`, restrict inbound to the Sentinel CCF service, and use a
  Key Vault private endpoint. The Consumption plan used by `azuredeploy.json` is public-egress.
- **Scaling.** The proxy is stateless and CPU-light (HMAC + forward); Consumption autoscales fine.
  Application Insights (deployed) gives request/latency/failure telemetry — alert on `requests` 4xx/5xx.
```
