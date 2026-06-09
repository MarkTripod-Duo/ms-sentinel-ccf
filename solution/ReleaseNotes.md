| **Version** | **Date Modified (DD-MM-YYYY)** | **Change History**                                  |
|-------------|--------------------------------|-----------------------------------------------------|
| 1.0.0       | 09-06-2026                     | Initial release. CCF connector for Duo Admin API v2 authentication/activity/telephony logs (via an HMAC signing proxy) into custom `DuoSecurity*_CL` tables. Forward-compatible replacement for the legacy HTTP Data Collector API connector (retires 2026-09-14). Includes a backward-compatible `CiscoDuo` parser (dual-run with the legacy `CiscoDuo_CL` table), 10 analytic rules + a connector data-ingestion-stopped health rule, 10 hunting queries, an ASIM Authentication parser, and the Cisco Duo workbook. |

## Migration notes

- **Dual-run:** the `CiscoDuo` parser normalizes both the new `DuoSecurity*_CL` tables and the legacy
  `CiscoDuo_CL` table, so the legacy Azure Function connector and this CCF connector can run in parallel
  during cutover. Decommission the legacy connector before the HTTP Data Collector API retires (2026-09-14).
- **Scope:** Trust Monitor (end-of-life) and all v1 log endpoints (administrator, offline_enrollment) are
  intentionally not carried over. The v2 **activity** stream is the supported successor to the v1
  administrator log.
- **Admin-activity action mapping (validated against live v2 data):** the authentication-based detections and
  hunts are fully working end to end. The v2 activity log exposes the action name at `action.name` (an
  object) and uses a different taxonomy than the v1 administrator log - observed values include
  `admin_sync_begin`/`admin_sync_finish`, `admin_activate_duo_push`, `phone_activation_code_regenerated`. The
  admin-centric rules/hunts filter on v1 names (`admin_create`, `user_delete`, `admin_2fa_error`,
  `admin_login_error`, `admin_reset_password`, `ad_sync_failed`), which do **not** match the v2 names, so
  those detections are **adapted but dormant** until the v2->v1 mapping is completed against a production
  tenant (the demo tenant does not exercise create/delete/login-failure admin events). The parser passes the
  raw v2 `action.name` through to `DvcAction`, so analysts can hunt on the real v2 actions today; extend the
  `CiscoDuo` activity branch's mapping as production action names are confirmed.
