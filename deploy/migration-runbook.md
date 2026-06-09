# Migration runbook: legacy Cisco Duo connector → CCF

For customers moving off the upstream **`CiscoDuoSecurity`** solution (an Azure Function that ingests via
the **HTTP Data Collector API**) to this CCF connector, with **zero detection downtime**.

## Why / when

The Azure Monitor **HTTP Data Collector API retires 2026-09-14**. The legacy Duo connector uses it
(`sentinel_connector.py`: SharedKey signature, `Log-Type` header, `POST /api/logs`) and will stop
ingesting. This CCF connector uses the Logs Ingestion API + DCRs and is the forward-compatible
replacement. **Complete the cutover before 2026-09-14.**

The migration is **non-destructive and reversible** at every step before decommissioning.

## Audience & prerequisites

For the **Microsoft Sentinel / SOC administrator** performing the cutover. You need: Contributor on the
Sentinel workspace's resource group; the Duo Admin API application (ikey / skey / `api-…duosecurity.com`
host) with the **Grant read log** permission; and access to the existing `CiscoDuoSecurity` Function
connector. Detailed deploy steps are in [`enable-connector.md`](enable-connector.md); production hardening
(including zero-gap ingestion) is in [`operations.md`](operations.md). Budget a few days of dual-run overlap
before cutover.

## How it stays seamless: dual-run via the parser

The `CiscoDuo` parser `union`s the legacy `CiscoDuo_CL` table **and** the new `DuoSecurity*_CL` tables into
one alias schema. So the existing analytic rules, hunting queries, and workbook keep working against
**both** data sources at once — you can run the old and new connectors in parallel and cut over with no
gap and no rule rewrites.

## Steps

**0. Pre-flight (T-minus weeks).**
- Inventory what depends on `CiscoDuo_CL`: analytic rules, hunting queries, workbooks, custom queries,
  saved functions. (The upstream solution's own rules already use the `CiscoDuo` parser.)
- Note your legacy table retention — you'll want to keep `CiscoDuo_CL` queryable through the overlap.

**1. Deploy the signing proxy + CCF connector + content (new, alongside the old).**
- Run `deploy/deploy-proxy.sh` → `deploy/deploy-ingestion.sh` → `deploy/deploy-connector.sh`, **or** deploy
  the assembled package (`deploy/build-package.sh` → `solution/Package/mainTemplate.json`), which creates the
  connector, DCE/DCR/tables, parsers, rules, hunts, and workbook in one step. See
  [`enable-connector.md`](enable-connector.md).
- The legacy Azure Function connector keeps running untouched.
- For production, consider enabling the zero-gap overlap (`DUO_MINTIME_LOOKBACK_SECONDS`) — see
  [`operations.md`](operations.md).

**2. Confirm the `CiscoDuo` parser supersedes the legacy one (this enables dual-run).**
- This solution's `CiscoDuo` parser (v2.0.0) uses the same `FunctionAlias: CiscoDuo`, so it **replaces** the
  legacy parser and adds the new-table branches — existing rules/hunts/workbook immediately read **both** old
  and new data through it. (If you deployed via the scripts rather than the package, install the parser +
  content now; the package in step 1 already did.)
- This solution's analytic rules/hunts (new GUIDs) coexist with the legacy ones; disable the legacy
  duplicates whenever you're ready.

**3. Verify the new pipeline (overlap period: a few days).**
- New tables populate: `DuoSecurityAuthentication_CL | take 10`, plus activity/telephony.
- The unified parser returns both sources: `CiscoDuo | summarize count() by EventVendor, bin(TimeGenerated, 1h)`
  should show a continuous stream spanning the legacy and CCF tables.
- Detections still fire (deploy + confirm as in the test workspace).
- Confirm no time gap at the handover: events are present in `CiscoDuo_CL` up to the cutover and in
  `DuoSecurity*_CL` from connector start, with overlap.

**4. Cut over.**
- Once the CCF connector has a stable overlap, **stop the legacy Azure Function** (disable the timer
  trigger or stop the Function App). `CiscoDuo_CL` stops growing; `DuoSecurity*_CL` continues. The parser
  keeps serving historical `CiscoDuo_CL` data, so dashboards/hunts over past data are unaffected.
- Disable any duplicate legacy analytic rules in favor of this solution's versions.

**5. Decommission (before 2026-09-14).**
- Delete/uninstall the legacy connector's Function App, storage, and the `CiscoDuoSecurity` Function-based
  data connector. Remove the legacy Workspace shared-key usage.
- Keep `CiscoDuo_CL` for its retention period (the parser still unions it); it ages out naturally. No need
  to delete it — `union isfuzzy=true` tolerates it being gone once it's fully aged out.

## Schema note

The legacy table is flat (`access_device_ip_s`, `action_s`, …); the new tables are nested `dynamic`
(`access_device`, `action`, …). **You don't remap anything** — the `CiscoDuo` parser normalizes both to the
same aliases (`SrcIpAddr`, `DvcAction`, `EventResult`, …). Only the v1→v2 admin **action names** differ; see
[ReleaseNotes](../solution/ReleaseNotes.md) for which admin detections are confirmed, mapped, or pending.

## Rollback

Before step 5, rollback is trivial: re-enable the legacy Function connector. Both feed the parser, so
detections never lose coverage. After decommissioning, rollback means redeploying the legacy connector
(possible until the HTTP Data Collector API retires).
