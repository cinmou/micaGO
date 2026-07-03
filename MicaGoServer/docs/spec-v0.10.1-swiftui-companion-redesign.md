# v0.10.1 SwiftUI Companion Redesign

Status: **Planning** (spec only; no code in this pass). Companion-side follow-up
to [`spec-v0.10.0-mac-companion.md`](spec-v0.10.0-mac-companion.md), informed by a
focused UI/product-surface read of the BlueBubbles server app.

## Goal

Reorganize the micaGO macOS companion from a single scrolling window into a
**native SwiftUI sidebar app** with clear product surfaces, using BlueBubbles'
server-management app **only as a reference for feature coverage and information
architecture** — not its implementation.

Hard boundaries (unchanged):
- Native macOS **SwiftUI**, sidebar-based (`NavigationSplitView`). **No WebUI**,
  no Electron/React, no Chakra, no Socket.IO, no BlueBubbles API shapes.
- The **Go server is the real service**; the **SwiftUI app is the local
  controller** (launches the binary, reads the local API).
- **Local + LAN endpoints are always shown** when available; **public URL is an
  optional extra** endpoint, never a mode.
- **Firebase is future v0.12** self-host support only.
- Notifications show **provider status now**; full FCM setup comes later.
- **Privacy-sensitive values hidden by default** — bearer token and push tokens
  masked, reveal-on-demand, never logged.

## BlueBubbles server UI areas inspected

Read under `bluebubbles server/packages/ui/src/app/` (React/Electron — reference
only):
- **Navigation** (`containers/navigation/Navigation.tsx`): Home, Contacts,
  Android Devices, Notifications, Scheduled Messages, API & Webhooks, Debug &
  Logs, Guides & Links, Settings.
- **Home/Dashboard** (`layouts/home/HomeLayout.tsx`): server address + copy + QR,
  an HTTP-insecure warning, and message **stats** (total messages, top group,
  best friend, daily messages, pictures, videos).
- **Settings → Connection** (`layouts/settings/connection/`): proxy service
  selector (Ngrok/Cloudflare/zrok/Dynamic-DNS), Ngrok auth token/subdomain, zrok
  token/reserved tunnel, **server password**, **local port**, **use HTTPS**.
- **Notifications** (`layouts/notifications/`): Firebase config — auto-create via
  OAuth **or** manual `google-services.json` + service-account JSON upload;
  "configured / not configured" status; clear FCM config; real-time DB URL
  validation; server-URL-change delivery via Firebase.
- **Devices** (`layouts/devices/`): registered Android devices (name, identifier,
  last active), auto-refresh, clear devices.
- **Debug & Logs** (`layouts/logs/`): live log stream, debug toggle,
  Messages-app-logs filter, clear logs, **clear event cache**, copy binary path,
  restart.
- **Settings (other)**: Features (Private API toggle, webhooks, encrypt comms),
  Database, Update (auto-update), Reset, Theme, Private API.
- **Permissions** (walkthrough `layouts/walkthrough/permissions/` + server
  `checkPermissions`): Full Disk Access, Accessibility/Automation guidance.

## Feature coverage we should keep

Adopt these **concepts** (rebuilt natively, not copied):
- A **Dashboard** that answers "is it running, where do I reach it, is it
  healthy" at a glance (status, primary URL, copy/QR, sync freshness).
- A **Connections** surface for local/LAN/public endpoints + pairing QR.
- A **Push Devices** surface listing registered notification devices with
  per-device actions (test push, remove).
- A **Notifications** surface showing provider status.
- A **Permissions** surface (Full Disk Access, Automation, plus Messages.app
  running) with remediation guidance.
- **Server controls** (start/stop/restart, binary path).
- **Logs/diagnostics** for troubleshooting.
- An **Advanced** surface for power settings and capability/diagnostic detail.

## Feature coverage we should simplify

- **Remote access**: no in-app proxy management. We **store/validate a
  user-produced public URL** only (`/api/server/public-url` + `…/check`); the
  user runs Cloudflare Tunnel/Ngrok/reverse-proxy/DDNS themselves. Tailscale is
  documented as advanced; never embedded.
- **Notifications**: read-only **provider status** now (enabled/provider/preview,
  implemented vs stub). Full **FCM self-host setup** (service-account import,
  Firestore public-URL sync) is **v0.12**, shown here as a clearly-labeled
  "planned" panel.
- **Logs**: show the **launched server process log** (already captured) plus WS
  event activity; a richer server-side log/diagnostics API is *planned* (see
  Required APIs). No "event cache" console.
- **Permissions**: probe + guidance. Automation cannot be auto-detected; show
  "verify in System Settings" with a deep link.
- **Stats**: not a priority. The companion is a **controller, not analytics**; at
  most show counts already in `/api/server/status` (devices, websocket clients).

## Things we should not copy

- BlueBubbles **React/Electron/Chakra UI** code or component structure; its
  routing/state (Redux) model.
- **Socket.IO** and BlueBubbles **API shapes / response envelopes**.
- **Private API** feature toggles (typing/reactions/edit/unsend send, dylib).
- **Scheduled Messages, Contacts management, FindMy, API & Webhooks** as product
  surfaces.
- **Firebase auto-bootstrap / OAuth project creation** — micaGO is self-host
  only, later.
- "**Best friend / top group**" and other message-content analytics.
- **Auto-update service**, encrypt-communications field, **in-app management of
  ngrok/cloudflare/zrok** binaries.

## Proposed micaGO Companion structure

A `NavigationSplitView` with a sidebar of eight destinations and a detail pane.
A persistent header/footer chip shows reachability (green/grey dot), server
version, and a Start/Stop quick action regardless of the selected destination.

Sidebar:

```
Dashboard
Connections
Push Devices
Notifications
Permissions
Server
Logs
Advanced
```

### Dashboard
At-a-glance health. Running dot + `version`/`uptime`; **primary local URL** with
copy + QR shortcut; reachability + auth-valid; **sync status** (`lastSyncAt`,
loop on/off, interval); websocket client count; device count; Messages.app
running. Primary Start/Stop/Restart. Inline warnings (token rejected, FDA
denied, Messages not running). Source: `/api/server/status` + local checks.

### Connections
The current "Connection Endpoints" surface. **Local** and **LAN** endpoints
(always shown when available) with copy; **Public URL** editor (set/clear) +
**Validate** + reachability/provider hint; **bearer token** masked with
reveal/copy; **pairing QR** with a Local/LAN/Public endpoint picker. Source:
`/api/server/urls`, `/api/server/public-url[/check]`, config token (local read).

### Push Devices
List from `/api/devices`: name, platform, clientType, push provider,
`pushEnabled`, `pushTokenSet` (token never shown), `lastSeenAt`. Per-device
**Test Push** (`POST /api/devices/{id}/test-push`) and **Remove**
(`DELETE /api/devices/{id}`). Manual refresh.

### Notifications
Provider status (read-only now): `enabled`, `provider`, `preview`,
`implemented` vs `stub` lists, webhook-configured indicator. A clearly-labeled
**"FCM self-host (v0.12) — planned"** panel describing future
service-account import + Firestore public-URL sync, with the privacy rules
restated. Source: `notifications` block of `/api/server/status`.

### Permissions
Full Disk Access, Attachments, Automation (from `/api/server/status`
`permissions`) with status dots; **Messages.app running** (local NSWorkspace);
remediation buttons: open the relevant System Settings privacy panes, Open
Messages. Automation shown as "verify in Settings" (not auto-probeable).

### Server
Process control: **binary path** (with file picker), **Start / Stop / Restart**,
detected bind address, `store` (relaydb/chatdb), sync interval, version. This is
the authoritative process-control surface (Dashboard mirrors the quick action).

### Logs
The launched server **process log** (captured stdout/stderr) with copy/clear,
plus an optional **live event feed** of WebSocket events (`message:new`,
`message:update`, `message:unsend`, `send:*`, `sync:error`) for troubleshooting.
Note when logs are unavailable (server not launched by this companion).

### Advanced
Power/diagnostic settings: **`capabilities.schema`** (edited/unsent/read/
delivered/sendError/groupActions/attachmentMetadata) as a read-only matrix;
`sync.update_lookback`, `verify_tls`, `preferred_pairing_endpoint`; config file
path; **Keep Awake** toggle (companion `caffeinate`); **Launch at Login**;
links to specs. Destructive/local-only actions live here.

## Required server APIs

### Already available
- `GET /api/health` — liveness (no auth).
- `POST /api/auth/check` — token validity.
- `GET /api/server/info` — name/version/features/providers.
- `GET /api/server/status` — version, uptime, address (local/LAN), store, auth,
  sync, notifications (provider/implemented/stub), devices count, websocket
  clients, permissions (FDA/attachments/automation), **capabilities.schema**.
- `GET /api/server/urls` — grouped local/LAN/public endpoints + preferred pairing.
- `POST /api/server/public-url`, `POST /api/server/public-url/check`.
- `GET /api/devices`, `POST /api/devices/{id}/test-push`, `DELETE /api/devices/{id}`,
  `PATCH /api/devices/{id}`, `POST /api/devices/{id}/heartbeat`.
- `GET /ws` — realtime events for the Logs event feed.

### Missing / planned
- **Notifications config write** (provider/preview/webhook URL): currently only
  editable in `config.yaml`. *Planned* — add `POST /api/server/notifications`
  (provider/preview/webhook) so the Notifications surface can configure without
  hand-editing YAML. Until then, Notifications is read-only + guidance. (Full FCM
  setup is v0.12.)
- **Server log access** (optional): the companion can only show the process it
  launched. *Planned (optional)* — a bounded `GET /api/server/logs` tail or a WS
  `log` event so Logs works when the server was started independently. Low
  priority; the process log covers the common case.
- **Manual "sync now"** (optional): *Planned (optional)* — `POST /api/server/sync`
  to force a sync tick from the Dashboard. Not required (the loop already syncs).
- **Lightweight counts/stats** (optional, privacy-light): `/api/server/status`
  already exposes device + websocket counts. A `GET /api/server/stats`
  (chat/message totals) is **explicitly low priority**; no message-content
  analytics. Likely **skip**.
- **No** server-restart API needed — the companion controls the process directly.

## SwiftUI implementation plan

Sequenced so each step is shippable; **implementation is a later pass**.

1. **Shell**: `NavigationSplitView` with a `Sidebar` enum (8 cases, SF Symbols),
   a `selection` state, and a persistent status chip (reachable dot + version +
   Start/Stop). Keep `AppModel` as the single `@MainActor ObservableObject`;
   add a `selectedSection` published property.
2. **Refactor existing sections into destinations**: move the current
   `ServerControlSection` → **Server**, `ConnectionEndpointsSection` +
   `TokenSection` → **Connections**, `DevicesSection` → **Devices**,
   `NotificationsSection` → **Notifications**, `DiagnosticsSection` +
   `RuntimeSection` permission rows → **Permissions**, `RuntimeSection`
   keep-awake + `LaunchAtLoginSection` → **Advanced**, `ServerLogSection` →
   **Logs**. New **Dashboard** composes the most important status at a glance.
3. **Devices actions**: wire Test Push + Remove (APIs already exist) with
   confirmation for Remove.
4. **Logs event feed (optional)**: a small WS client appending decoded events to
   a bounded list; off by default.
5. **Advanced capabilities matrix**: render `capabilities.schema` from status.
6. **Polish**: empty/disconnected states, keyboard navigation, window min-size,
   consistent privacy masking.

Keep one reusable `SectionCard`, copy/QR helpers, and the polling model. No new
third-party dependencies; CoreImage for QR (already used).

## Manual test checklist

1. App launches into **Dashboard**; sidebar lists the 8 destinations; switching
   destinations keeps the status chip visible.
2. With the server stopped: Dashboard shows "Stopped"; Start works from both the
   chip and the **Server** page.
3. **Connections**: local + LAN endpoints appear when bound to `0.0.0.0`; only
   local when loopback. Public URL set/validate works; token is **masked** until
   Reveal; pairing QR regenerates per selected endpoint.
4. **Push Devices**: registered notification devices list; Test Push returns success/▲not-configured;
   Remove deletes after confirm; push token is never shown (only "token set").
5. **Notifications**: provider/preview and implemented vs stub render; the v0.12
   FCM panel is clearly labeled "planned".
6. **Permissions**: FDA/Automation/Messages-running statuses render; remediation
   buttons open the right System Settings panes / Messages.
7. **Server**: binary path picker; Start/Stop/Restart; bind address + store +
   version shown.
8. **Logs**: process log streams with copy/clear; (optional) event feed shows
   live `message:*`/`send:*` events.
9. **Advanced**: capabilities matrix matches the running Mac; Keep Awake toggle
   activates `caffeinate`; Launch at Login toggles.
10. Build: `xcodebuild … CODE_SIGNING_ALLOWED=NO build` succeeds; no secrets in
    logs; no WebUI/Electron/Socket.IO introduced.
