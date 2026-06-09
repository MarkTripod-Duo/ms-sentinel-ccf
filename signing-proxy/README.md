# Duo v2 logs — HMAC signing proxy

A ~80-line stateless Azure Function (Python, v2 model) that signs Duo Admin API v2 log requests with
HMAC-SHA1 so Microsoft Sentinel's Codeless Connector Framework can poll Duo. See the
[top-level README](../README.md) for *why* this exists.

## What it does

For each inbound CCF poll it:
1. validates the route (`authentication` | `activity` | `telephony`);
2. forwards the inbound query string (`mintime`, `maxtime`, `limit`, `next_offset`, `sort`, …) to
   Duo, signing it with [`duo-hmac`](https://pypi.org/project/duo-hmac/) — `Date` + `Authorization`
   headers, signature over the sorted params;
3. returns Duo's JSON verbatim, except it joins the authentication-log `next_offset` array into a
   comma string so CCF's `NextPageToken` pager can resend it;
4. passes Duo `429` + `Retry-After` straight back so CCF can back off.

| Route | Duo endpoint | Events JSON path (consumed by CCF) |
| --- | --- | --- |
| `GET /api/duo/authentication` | `/admin/v2/logs/authentication` | `$.response.authlogs` |
| `GET /api/duo/activity` | `/admin/v2/logs/activity` | `$.response.items` |
| `GET /api/duo/telephony` | `/admin/v2/logs/telephony` | `$.response.items` |

## Configuration (app settings)

| Setting | Value |
| --- | --- |
| `DUO_IKEY` | Duo Admin API integration key (`DI…`) |
| `DUO_API_HOST` | `api-XXXXXXXX.duosecurity.com` |
| `DUO_SKEY` | **Key Vault reference** → `@Microsoft.KeyVault(VaultName=…;SecretName=DUO-SKEY)` |

`azuredeploy.json` provisions the Function App (system-assigned identity), Storage, Application
Insights, and a Key Vault holding `skey`, and grants the identity **Key Vault Secrets User**.

## Auth model

- **Inbound (CCF → proxy):** Azure Functions **function key** (`AuthLevel.FUNCTION`). CCF sends it as
  the `x-functions-key` header via its APIKey auth. Not an open relay.
- **Upstream (proxy → Duo):** HMAC-SHA1 with `ikey`/`skey`. `skey` lives only in Key Vault.

## Deploy

```bash
# 1. Infra
az deployment group create -g <rg> -f azuredeploy.json \
  -p functionAppName=<name> duoApiHost=api-XXXXXXXX.duosecurity.com \
     duoIkey=DIXXXXXXXXXXXXXXXXXX duoSkey=<skey>

# 2. Code
func azure functionapp publish <name> --python

# 3. Get the function key (used by the Sentinel connector)
az functionapp keys list -g <rg> -n <name> --query functionKeys.default -o tsv
```

See [`../deploy/deploy-proxy.sh`](../deploy/deploy-proxy.sh) for a scripted version.

## Run locally

```bash
cp local.settings.json.sample local.settings.json   # fill in real Duo creds (never commit)
pip install -r requirements.txt
func start
# epoch-ms window; mintime within the last 180 days, maxtime ≤ now-2min
curl "http://localhost:7071/api/duo/authentication?mintime=1717200000000&maxtime=1717203600000&limit=10"
```

Expect `{"stat": "OK", "response": {"authlogs": [...], "metadata": {...}}}`.

## Multi-account variant (optional)

The default is **one Duo account per proxy** (ikey/host/skey in config). To serve several Duo
accounts from one proxy: have CCF pass `ikey` (and optionally `host`) as query params, look up the
matching `skey` in Key Vault by ikey, and strip those two params before signing (Duo must not
receive them). Keep them in `_CONTROL_PARAMS` so they are never forwarded to Duo.
