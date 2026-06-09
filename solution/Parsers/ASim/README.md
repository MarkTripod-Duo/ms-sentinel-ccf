# ASIM parsers for Cisco Duo

Source-specific [ASIM](https://aka.ms/AboutASIM) parsers that normalize Duo's v2 authentication logs to
the **ASIM Authentication** schema (v0.1.3), for cross-product, vendor-agnostic queries and content.

| Parser | Type | Purpose |
| --- | --- | --- |
| `ASimAuthenticationDuoSecurity` | parameter-less | Normalized view of `DuoSecurityAuthentication_CL` |
| `vimAuthenticationDuoSecurity` | filtering | Same, with the standard ASIM filtering parameters (pushdown) |

## Conformance

Validated against the official ASIM testers on live data:

- **Schema test** (`… | getschema | invoke ASimSchemaTester('Authentication')`): **0 errors**. The 6
  remaining *warnings* are recommended fields Duo's auth-to-application log doesn't carry (`Dst`,
  `DvcAction`, `DvcDomain/Hostname`, `TargetDomain/Hostname`) — source limitations, not defects.
- **Data test** (`… | invoke ASimDataTester('Authentication')`): **0 errors**. `LogonMethod` maps to the
  ASIM enum (`Multi factor authentication`, or `Passwordless` for WebAuthn/FIDO factors); `EventResultDetails`
  maps Duo `reason` values to the ASIM enum. The raw Duo `factor`/`reason` are preserved in
  `AdditionalFields` so nothing is lost.

## Using them

Query the source parser directly:

```kusto
ASimAuthenticationDuoSecurity | where EventResult == "Failure" | take 10
imAuthentication | where EventProduct == "Duo Security"     // once included in the unified parser (below)
```

## Including Duo in the unified `imAuthentication`

This version of the central `imAuthentication`/`ASimAuthentication` parsers has **no `Custom` extension
placeholder**, so a custom source is added one of two ways:

1. **Built-in (for publication):** submit `vim`/`ASimAuthenticationDuoSecurity` to Microsoft's ASIM via a
   PR to `Azure-Sentinel/Parsers/ASimAuthentication/` — Microsoft adds `vimAuthenticationDuoSecurity` to the
   built-in `_Im_Authentication` union. The parsers here are conformance-tested and PR-ready.
2. **Workspace override (immediate):** deploy a workspace-scoped `imAuthentication` function that unions the
   built-in with Duo, so existing ASIM content sees Duo without waiting for a PR:

   ```kusto
   // FunctionName/Alias: imAuthentication  (shadows the built-in for this workspace)
   let DisabledParsers = materialize(_GetWatchlist('ASimDisabledParsers') | where SearchKey in ('Any', 'ExcludeimAuthentication') | extend SourceSpecificParser='' | distinct SourceSpecificParser);
   let imAuthenticationDisabled = toscalar('ExcludeimAuthentication' in (DisabledParsers) or 'Any' in (DisabledParsers));
   union isfuzzy=true
       _Im_Authentication(starttime=starttime, endtime=endtime, username_has_any=username_has_any, targetappname_has_any=targetappname_has_any, srcipaddr_has_any_prefix=srcipaddr_has_any_prefix, srchostname_has_any=srchostname_has_any, eventtype_in=eventtype_in, eventresultdetails_in=eventresultdetails_in, eventresult=eventresult, disabled=(imAuthenticationDisabled or disabled)),
       vimAuthenticationDuoSecurity(starttime=starttime, endtime=endtime, username_has_any=username_has_any, targetappname_has_any=targetappname_has_any, srcipaddr_has_any_prefix=srcipaddr_has_any_prefix, srchostname_has_any=srchostname_has_any, eventtype_in=eventtype_in, eventresultdetails_in=eventresultdetails_in, eventresult=eventresult, disabled=(imAuthenticationDisabled or disabled))
   ```
   (Deploy with the same `ParserParams` signature as the built-in. Remove the override after Duo lands in
   the built-in to avoid divergence.)

## Follow-up: ASIM Audit for the activity stream

The **activity** stream (admin CRUD) maps naturally to the ASIM **Audit Event** schema
(`*_create`→`EventType="Create"`, `*_delete`→`"Delete"`, `*_update`→`"Set"`, `*_view`→`"Read"`; `actor`→Actor,
`target`→Object). A `vim`/`ASimAuditEventDuoSecurity` pair is a clean addition — not built here yet.
