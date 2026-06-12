# Operations & production hardening

Operational guidance for running the Duo CCF connectors (built‑in `CiscoDuo` auth, no proxy) in production.

## 1. Data completeness (the trailing-edge gap)

**The constraint.** Duo's Admin API has a deliberate **~2-minute availability delay** — events younger
than ~2 minutes are not yet returned. Microsoft Sentinel CCF uses **service-managed, time-based
checkpointing**: each poll's start time is the *last run time* (wall clock), advanced by the service after
the run; CCF **cannot persist a custom cursor** (`next_offset`) across runs. The result: an event that is
still inside Duo's 2-minute delay window when a poll runs can fall *before* the next poll's start time and
be **skipped** — a rare trailing-edge gap.

**There is no proxy knob anymore.** Earlier versions widened `mintime` in the signing proxy; with the
native `CiscoDuo` auth type the poll window is fully service-managed, exactly like Microsoft's official Duo
connector. In practice the gap is rare (it needs an event to both arrive late *and* sit on a poll boundary).

**Mitigations.**
- **Monitor freshness.** The *Cisco Duo - Data ingestion stopped* analytic rule alerts when no Duo data has
  arrived for longer than a threshold — the practical guardrail against a silent stall.
- **De-duplicate by `txid` at query time** if you ever re-Connect a connector or widen `queryWindowInMin`
  (both can re-ingest a small overlap). Dedup is intentionally *not* baked into the table or the `CiscoDuo`
  parser (it would slow every query):
  ```kusto
  DuoSecurityAuthentication_CL
  | summarize arg_max(TimeGenerated, *) by txid
  ```
- A modest **`queryWindowInMin`** (the connectors ship `5`) keeps each poll's window small; raising it
  re-reads more recent history per poll (more overlap, more duplicates) but narrows the gap.

## 2. Rotating the Duo credentials

The Duo `skey` (and `ikey`/host) are held by the CCF connector, entered at Connect time — **not** in a Key
Vault. To rotate:

1. Create the new Secret Key in the **Duo Admin Panel** (it can coexist with the old one briefly).
2. In **Microsoft Sentinel → Data connectors**, open each Cisco Duo connector, **Disconnect**, re-enter the
   API host / integration key / new secret key, and **Connect** again.
3. Confirm data resumes, then delete the old key in Duo.

For the scripted deploy, re-run `deploy/deploy-connector.sh` with the new `--skey` (it re-PUTs the pollers).
Set a calendar reminder; Duo does not expire keys automatically.

## 3. Multiple Duo accounts

The model is **one connector set per Duo account**. Each connector's Connect holds its own ikey / host /
skey, so to ingest from several Duo tenants, deploy the solution once per tenant (a separate workspace, or
re-Connect a second set of connectors with the other tenant's credentials). Keep one DCE/DCR set per
workspace; a tenant column or `actor`/`akey` in the data distinguishes accounts.

## 4. Rate limits, scaling & networking

- **Rate limits.** Duo returns `429` with `Retry-After`; CCF honors both natively and backs off
  (`retryCount: 3`). The connectors ship a modest `rateLimitQPS` (2); for adaptive backoff under load add
  `request.rateLimitConfig` (`OnlyWhen429` + `useResetOrRetryAfterHeaders`).
- **One connection per stream.** Run a single CCF connection per log type to avoid racing the shared
  time checkpoint; parallel connections against the same stream can double-ingest or interleave.
- **No infrastructure to manage.** There is no Function App, Storage, Key Vault, or VNet — the polling
  engine and its egress to `*.duosecurity.com` are Microsoft-managed. Restrict access to Duo at the Duo
  Admin API application level (e.g. the Admin API app's allowed networks) rather than at an Azure proxy.
- **Telemetry.** Connector health is visible on each connector page (last data received) and via the
  *Cisco Duo - Data ingestion stopped* rule.
```
