# v0.12.0 — Firebase Self-Host Push

Status: **Planned** (spec only; no code in this pass). Comes **after** the
runtime/deployment (v0.11.2), sync-control (v0.11.3), and contacts (v0.11.4)
foundations.

## Goal

Add **self-hosted Firebase** support: real **FCM push** delivery using the
user's own Firebase project, and **optional Firestore sync of the public URL
only** so remote clients can rediscover a changed tunnel URL. This replaces the
current `fcm` stub (`501`).

## BlueBubbles reference inspected

`server/services/fcmService/index.ts` (from
[`bluebubbles-source-audit-v2.md`](bluebubbles-source-audit-v2.md)): self-host
Firebase via the user's `clientConfig`/`serverConfig`; stores **only `serverUrl`**
in Firestore (`collection("server").doc("config").set({ serverUrl })`); FCM
`sendEachForMulticast` with a `data` payload + 24h TTL; prunes
`registration-token-not-registered`; an `addressUpdateService` keeps the URL
fresh. We adopt the **data model and privacy posture**, not the OAuth
auto-bootstrap or any chat storage.

## Design

### FCM push delivery

- Implement the existing `fcm` provider in `internal/notify/` (currently a stub)
  to deliver via the **FCM HTTP v1 API** using the user's **service account**
  (`fcm.service_account_path` already in config) for OAuth2 (JWT → access token,
  cached/refreshed). Avoid heavy SDKs; a minimal token+HTTP client is preferred.
- Delivery is **multicast** to the registered device push tokens (from the
  device registry, `pushProvider == "fcm"`, `pushEnabled`). Reuse the existing
  `Notification` payload (`type`, `messageGuid`, `chatGuid`, `title`, `body`,
  `previewMode`, `createdAt`) as the FCM `data` payload.
- Wire into the existing dispatch path (`DispatchNewMessages` on sync), so push
  rides the same flow as the webhook provider.

### Import / setup of Firebase config

- **Manual, self-host only.** The user supplies their own Firebase project's
  **service account JSON** (server-side, referenced by `fcm.service_account_path`)
  and the client-facing config (project id / sender id) needed by client apps.
- The companion's **Notifications** page gains a setup panel: choose provider
  `fcm`, point at the service-account file, set `previewMode`, enable. This
  requires the notification-config write API (planned in the v0.10.1 spec's
  "missing APIs"); add `POST /api/server/notifications` to set
  provider/preview/enabled (never returns secrets).
- **No automatic Firebase project creation** and **no OAuth-heavy bootstrap** in
  this version (explicitly deferred; would require separate research/approval).

### Test push

- Use `POST /api/server/notifications/test`. With `fcm` implemented, it sends a
  real test notification through the user's project to every registered FCM
  device and reports success / `push_no_devices` / `push_no_fcm_devices` /
  provider error. Surfaced by the Notifications setup page.

### Device token pruning

- On send, treat FCM `UNREGISTERED` / `registration-token-not-registered`
  responses as a signal to **clear the stored push token** (or mark the device
  push-disabled) so dead tokens don't accumulate. Other transient errors are
  logged and retried on the next dispatch (no aggressive retry loop).

### TTL

- Set a message **TTL** (e.g. 24h) on FCM messages so stale notifications expire
  rather than delivering hours later. Configurable later; default 24h.

### previewMode

- Honor the existing `notifications.preview` (`none` | `sender` |
  `sender_and_text`). The FCM `data` payload's `title`/`body` content is gated by
  it exactly like the webhook provider:
  - `none` → no sender/text (generic "New message");
  - `sender` → sender label only;
  - `sender_and_text` → sender + message text.
- This is the **only** place message-derived text may enter a push, and only per
  the user's chosen preview level — never full chat history.

### Interaction with sync rules & push mute (v0.11.3)

- Push dispatch is **downstream of sync rules**: a message that is **sync-blocked**
  never reaches dispatch (no relay row), so it never pushes. A message that is
  **synced but push-muted** is excluded from FCM dispatch (and webhook).
- Net rule: `push = synced AND not push-muted AND device pushEnabled AND provider
  delivers`. The rule evaluator from v0.11.3 is the gate; v0.12 only adds the FCM
  delivery mechanism.

### Public URL sync when `network.public_base_url` changes

- **Optional, off by default.** When enabled and a Firebase project is
  configured, on a successful `POST /api/server/public-url` (or at startup if
  set), write **only** the public base URL to Firestore
  (`server/config { publicBaseUrl }`), so clients can rediscover a changed
  tunnel URL.
- Only the **URL string** is written — no token, no content. Firestore security
  rules should restrict reads to the user's authenticated clients (documented
  for the user to apply in their own project).

## Security boundaries

- The **service account JSON stays server-side** on the Mac; never returned by
  any API, never logged, never sent to clients.
- Bearer token and push tokens are never written to any **public** Firestore
  document. Push tokens live only in the local device registry (`relay.db`) and
  are sent to **Google FCM** as delivery addresses (that is their purpose), never
  published in a world/broadly-readable doc.
- Firestore usage is limited to a single small `server/config` document holding
  the public URL (when the optional sync is enabled).

### Data that must NEVER be stored in Firebase

- message content (beyond the user-selected `previewMode` text that transits a
  **transient FCM push**, which is delivery — not Firestore storage)
- contacts
- phone numbers
- bearer tokens
- push tokens in public documents
- attachments
- chat history

> Clarification: `previewMode` text may appear in a **transient FCM push
> message** (that is the notification), gated by the user's preview level. It is
> never **stored** in Firestore and never persisted server-side beyond
> `relay.db`. With `previewMode = none`, no message text transits at all.

## Non-goals

No Mica-operated cloud relay; no Firebase chat storage; no Firestore message
database; no automatic Firebase project creation (deferred pending research);
no OAuth-heavy BlueBubbles-style bootstrap.

## Required pieces (summary)

- Go: implement `internal/notify/fcm` (service-account OAuth2 + FCM HTTP v1
  multicast, TTL, token pruning); optional Firestore URL writer; add
  `POST /api/server/notifications` config-write endpoint.
- Config: reuse `fcm.service_account_path`, `notifications.{enabled,provider,preview}`;
  add an opt-in `firebase.public_url_sync` flag.
- Companion: Notifications setup panel (provider/service-account/enable) with a
  single "Send test notification" action.

## Manual test checklist

1. Configure `fcm` with a real service-account JSON; `/api/server/status`
   shows `fcm` in `implemented` (no longer a stub).
2. Register a device with an FCM token; **Send test notification** delivers a
   real notification; `push_no_fcm_devices` shown when no FCM device is registered.
3. `previewMode` levels produce the expected push content (none / sender /
   sender+text).
4. A **sync-blocked** chat never pushes; a **push-muted** chat syncs but does not
   push (v0.11.3 interaction).
5. An unregistered/expired token is pruned after a failed send.
6. Optional URL sync writes **only** `publicBaseUrl` to Firestore on change;
   inspect the doc to confirm no token/content/contacts.
7. Service-account JSON never appears in any API response or log; `go test ./...`
   green.
