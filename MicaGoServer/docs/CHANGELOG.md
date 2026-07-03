# MicaGo — version history

A consolidated, chronological record of MicaGo's development. Each entry is a
development cycle (internally tracked as **C-numbers**). This file replaces the
~45 per-cycle notes that previously lived in `docs/`.

Components: **Server** (Go relay on the Mac), **Companion** (macOS menu-bar app
that runs/manages the server), **Client** (Flutter Android app).

---

## 0.59.0 Beta — release polish, settings backup, and Companion lifecycle

- **Client.** Settings backup now includes the current connection profile, theme,
  language, chat background, custom avatars, muted chats, in-app notification
  preference, keep-alive preference, message display options, tablet sidebar
  width, pinned/hidden chat flags, hidden message tombstones, and user-owned FCM
  client options. It still excludes chat history, media, notification buffers,
  FCM tokens, realtime diagnostics, and the device id.
- **Client.** Chat and settings UI received final beta polish: safer keyboard
  inset recovery, larger emoji/sticker display, cleaner group footer spacing,
  input support for inserted images/GIFs where the platform provides them, and
  settings/about cleanup.
- **Companion.** Added an About page, localized settings via String Catalog, a
  Developer Mode gate for Debug/Log, and a lifecycle setting that starts and
  stops the bundled server with micaGO Companion.
- **Packaging.** Version numbers are aligned at **0.59.0** across the Flutter
  client, Go backend, macOS Companion, release docs, and DMG packaging script.

## C42 — Pin/hide + a two-way test-contact Debug card (backend v0.34)

- **Server.** `POST /api/test-contact/inbound` injects a message *from* the offline
  test contact and broadcasts it, so it pushes to the phone like a received
  iMessage. The test conversation **resets to just the greeting on each server
  start**. (Builds on C40's offline loopback test contact.)
- **Companion.** The Debug page gained a **Test Contact** card (pinned at the top):
  a two-way scratchpad that sends as the test contact and shows the phone's loopback
  replies. **Sync Control → Recent Messages** now shows the full raw set (matching
  the Debug inspector) with `[图片]`/`[文件]`-style placeholders instead of blank
  rows.
- **Client.** Pin a contact to the top or hide it (client-only "delete") — via
  **long-press** (Pin/Hide) or **swipe** (right clears the unread dot, left hides).
  Hide a single message from the thread (long-press → Hide). Settings → **Hidden
  items** restores hidden messages or hidden contacts. Cache schema **v4**
  (`chats.pinned` + a `hidden_messages` tombstone table). Fixed a latent bug where a
  server chat refresh reset the local hide/pin flags.

> Cycles C30–C41 (Companion UI/state, notifications, stickers/location/handwriting,
> voice send, docs restyle, the offline test contact, and unread badges) are tracked
> in `CLAUDE.md`.

## C29 — Keep-alive, Paired Devices, and registration reliability

- **C29 — Optional Android keep-alive.** Opt-in native foreground service
  (`KeepAliveService`, `dataSync` type) with a minimal persistent notification
  that keeps the app process — and thus the WebSocket + reconnect loop — alive in
  the background. Default **off**, exposed as an advanced setting, Firebase not
  required. Paired Devices was made to register on REST connect (not only on WS),
  and the device card reports push **or** keep-alive background status.
- **C29b — Registration runtime + first-connect error.** Device registration now
  uses a **dedicated short-lived API client** (immune to a concurrent
  `_rebuildApi()` close-race), returns `{status, error}` instead of swallowing
  failures, retries 3×, and logs the outcome on both client and server. Added a
  **10-second first-connection watchdog**: a clear "can't reach your server"
  dialog (with checks + Retry) instead of an endless "Reconnecting…", cleared
  the moment a connection succeeds; background reconnects never trigger it.
- **C29c — Full instrumentation + debug tool.** Every step of registration is
  logged (client connection log + backend `device register request…` /
  `device registered…`); ruled out store/route/schema/shape mismatches by
  inspection + tests; added a **Settings → Paired device debug** screen with a
  "Register device now" button and a live diagnostics panel (device ID, base URL,
  token status, WS state, last result). Idempotent re-register covered by tests.

## C28 — Android notifications + IMCore helper refresh

- **C28 (notifications) — Background delivery fix.** Audited the FCM chain vs
  BlueBubbles and produced a gap table. Fixed the core background bug: the FCM
  background isolate called `Firebase.initializeApp()` with **no options**, which
  throws on a fresh (killed-app) process since MicaGo bakes no
  `google-services.json`. Now the foreground **persists the runtime options** and
  the background handler re-initializes Firebase with them. Firebase stays
  optional throughout.
- **C28 (helper) — Rescan chain.** Fixed "installed helper still reports
  unavailable": added cache **invalidation** + `POST /api/messages/actions/refresh`
  so the backend re-probes immediately (no restart), broadcasts
  `capabilities:updated`, and exposes clear states (`missing`, `not_runnable`,
  `unsupported_selectors`, `ready`) in `/api/server/status` and the Companion.

## C27 — IMCore helper, push parity, media polish, Companion cleanup

- **C27 (real helper) — `micago-imcore-helper`.** Wrote a real, minimal
  Objective-C helper (ported from `Ref/imsg`) that performs Edit / Unsend /
  Delete via private IMCore selectors (`editMessageItem:…`, `retractMessagePart:`,
  `deleteChatItems:`), speaks the backend's stdin/stdout JSON protocol, and
  reports honest capabilities. Bundled into the Companion app (Xcode build phase
  compiles it into `Resources/`), installed to `~/.micago/bin` by the Install
  button, picked up by the backend. (Execution still depends on the Mac granting
  IMCore access; otherwise it reports unsupported — never a fake success.)
- **C27 (push/imsg/media).** Finished the FCM client surface (test-push button +
  push status card); produced an **imsg parity audit table** (what to migrate vs
  skip); polished chat media so image-only messages render as clean media cards
  without an outer chat bubble.
- **C27 (Companion UI cleanup + version).** Unified version reporting (Companion
  `MARKETING_VERSION` ↔ backend `version.Version`), made the launcher **prefer the
  bundled backend** over a stale cached one, showed all LAN addresses on the
  Dashboard, and removed duplicate/conflicting UI (single Public-URL source of
  truth, dropped redundant cards).

## C26 — Connection model hardening

- **C26 — Endpoint refresh + Public persistence.** LAN endpoints appear on
  startup without a Save; a saved Public URL survives backend/Companion restarts.
- **C26b — Reliability + cleanup.** IMCore helper capability detection + gating;
  fixed Android stuck "Reconnecting" while actually connected; **migrated
  loopback-only binds to a LAN-capable default** (the real root cause behind LAN
  not appearing); attachment-unavailable placeholders render as an unsent row,
  not a broken file card; consolidated duplicate reaction-GUID helpers.
- **C26c — Multi-LAN + helper install.** Profiles keep **all** advertised LAN
  routes with a persisted manual selection; a Settings route switcher; QR/JSON
  carries every candidate; the Install-helper flow + `~/.micago/bin` install path.

## C25 — LAN-primary connection model

Default bind became LAN-capable (`0.0.0.0:3000`); real interface IPs enumerated;
loopback dropped from pairing (Android can't reach `127.0.0.1`); Public URL is an
optional extra, never a mode. Companion + client adopted a candidate-list-only
model (removed the legacy loopback / This-Mac-only paths).

## C24 — Chat UI

Route selector shows the handle/address; emoji panel slides up (mutually
exclusive with the attachment panel); emoji-only messages render larger and
bubble-less; BlueBubbles-style full-screen image/video media viewer.

## C23 — Unified connection payload + Companion cleanup

Single server-authoritative connection payload with a config **revision** +
`connection:updated` event so clients follow URL changes without re-pairing.
Flutter unified pairing (scan/paste JSON → candidate store → auto-select).
Companion Dashboard/Status/Create-Connection reorganization; Log split from Debug;
obsolete pairing-mode state removed.

## C22 — Firebase / FCM (optional)

User-owned Firebase model (no `google-services.json` baked in): server serves the
client config at `/api/fcm/client`; the Flutter `PushService` initializes Firebase
at runtime, registers a token, and treats push as a thin **wake** signal —
message data always arrives over the socket / delta sync. Server FCM provider
(HTTP v1, data-only, preview-gated, dead-token pruning). Fully optional: with no
Firebase configured the app runs on WebSocket + delta sync.

## C21 — Effective service, media, delta sync

Server-authoritative **effective service** + explicit `canSendText` /
`canSendAttachments` (the client never re-derives sendability). BlueBubbles-style
attachment panel + multi-send; sticker/video media display; cursor-based **delta
sync** for catch-up; client contact merge + per-message route selector; composer
and timestamp/grouping polish; paired-device upsert (no duplicates).

## C20 — Refresh coordinator + SMS sendability

A single refresh tier (reconnect backoff + fallback poll + catch-up). Server-gated
"Allow SMS sending through Mac" setting (the client reads it, never guesses).

## C19 — Client usability

Server attachment-send endpoint; Flutter attachment picker/composer/states;
connection-status notifications; device identity registration so the Companion
shows connected clients.

## C18 — Startup decoupling + UI cleanup

Cloudflare tunnel decoupled from backend startup; dead-code sweep; Companion UI
reorganization (Debug page, Dashboard/Server/Advanced).

## C17 — Backend identity + freshness

Version package + `micago --version` + a backend-identity block in
`/api/server/status` (proves which binary is running). Companion freshness policy
and "restart with latest backend".

## C15 — chat.db open + error handling

Ported the imsg chat.db open pattern (dropped `immutable=1`) to fix malformed-DB
errors during live sync.

## C5–C14 — Foundations

Message-data reliability and BlueBubbles behavior audits (C5–C6); client
architecture + store rewrite (C7); BlueBubbles behavior migration, sync storage,
and endpoints (C9); local-DB pipeline, onboarding, and connection (C10); sync
audits and failure analysis (C11); the **imsg-based** new-message pipeline and
migration (C12–C13); network-privacy/traffic review; client-refresh reference
(C14). These established the one-directional flow:
`chat.db → sync loop → relay.db → REST/WebSocket → clients`.

---

For the design rationale of what MicaGo intentionally does and does **not** do,
see `MicaGoServer/docs/micago-feature-decision-matrix.md`.
