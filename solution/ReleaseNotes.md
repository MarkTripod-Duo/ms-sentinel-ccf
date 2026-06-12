| **Version** | **Date Modified (DD-MM-YYYY)** | **Change History**                                  |
|-------------|--------------------------------|-----------------------------------------------------|
| 1.0.0       | 09-06-2026                     | Initial release. Three per-endpoint CCF connectors for Duo Admin API v2 authentication/activity/telephony logs into custom `DuoSecurity*_CL` tables, using Microsoft's built-in **CiscoDuo** auth type (HMAC signing in the polling engine — no proxy). Forward-compatible replacement for the legacy HTTP Data Collector API connector (retires 2026-09-14). Includes a backward-compatible `CiscoDuo` parser (dual-run with the legacy `CiscoDuo_CL` table), 10 analytic rules + a connector data-ingestion-stopped health rule, 10 hunting queries, an ASIM Authentication parser, and the Cisco Duo workbook. |

## Migration notes

- **Dual-run:** the `CiscoDuo` parser normalizes both the new `DuoSecurity*_CL` tables and the legacy
  `CiscoDuo_CL` table, so the legacy Azure Function connector and this CCF connector can run in parallel
  during cutover. Decommission the legacy connector before the HTTP Data Collector API retires (2026-09-14).
- **Scope:** Trust Monitor (end-of-life) and all v1 log endpoints (administrator, offline_enrollment) are
  intentionally not carried over. The v2 **activity** stream is the supported successor to the v1
  administrator log.
- **Admin-activity action mapping (validated against two live tenants):** the authentication-based detections
  and hunts are fully working end to end. The v2 activity log carries the action name at `action.name`;
  `action.result` is null - an event's outcome is encoded in the action *name* (e.g. `*_sync_failure`).
  Harvested across tenants (180 days, ~28k events, 35+ distinct actions), the v2 taxonomy preserves the v1
  `<noun>_<verb>` convention. **Confirmed present with v1-matching names:** `admin_login`, `user_create`,
  `user_delete`, `group_create`, `group_delete`, `integration_create`/`update`, `policy_create`/`update`,
  `admin_update`, the sync events `admin_sync_*`/`entra_sync_*`, and the failure action
  `management_system_sync_failure`. The parser routes activity `DvcAction` through `DuoActivityActionMap`
  (pass-through by default).

  Per-rule status:
  - **Confirmed firing** - *Multiple users deleted* & *Deleted users* hunt (`user_delete`), *New users* hunt
    (`user_create`), and the user/group lifecycle hunts (exact v2 names verified present).
  - **Mapped** - *AD sync failed*: `DuoActivityActionMap` translates the `*_sync_failure` actions
    (`management_system_sync_failure` confirmed; `admin_/entra_/directory_sync_failure` inferred from the
    `*_sync_finish` vs `*_sync_failure` pattern) to `ad_sync_failed`, so the rule fires.
  - **Expected (convention; not exercised in-window)** - *New admin*, *Admin user deleted*, *Admin password
    reset*: v2 is expected to use `admin_create`/`admin_delete`/`admin_reset_password` (parallel to the
    confirmed `user_`/`group_` CRUD names); pass-through covers them. Confirm on a tenant that exercises
    these admin actions.
  - **Re-sourced from the authentication log (now firing)** - the *Multiple admin 2FA failures* analytic rule
    plus the *Admin 2FA failures* and *Admin failure authentications* hunts: the v2 activity log emits only
    successful `admin_login`, so these now query the authentication log filtered to the Duo Admin Panel
    application (`SrcAppName contains "Admin Panel"`) for non-successful results. Validated against live data
    (denied admin-panel sign-ins with reasons such as `locked_out`, `user_mistake`, `out_of_date`).
  - **Broadened for v2 robustness** - the *Delete actions* hunt now matches any administrative action whose
    name contains `delete` (instead of a fixed v1 name list), covering both the v1 and v2 delete taxonomies.
