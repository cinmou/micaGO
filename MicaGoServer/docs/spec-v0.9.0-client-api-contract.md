# MicaGoServer v0.9.0 Client-Facing API Contract

## Goal

Freeze a **stable, Mica-native** client API contract that future Windows
(Tauri), Android, Linux, and Flutter clients can build against without reading
the Go source. This document is the single source of truth for the wire format:
JSON models, REST endpoints, query parameters, error codes, and the WebSocket
event protocol.

This contract describes the API **as it is implemented today** (the handlers in
`internal/httpapi/` and the models in `internal/store/`). It does not invent new
endpoints; v0.9.0 is a documentation/stability milestone, not a feature
milestone.

## Non-goals (explicit independence from BlueBubbles)

The contract is intentionally **not** BlueBubbles client-compatible. The
following are out of scope and will not be added:

- No Socket.IO transport or BlueBubbles socket event names.
- No Firebase / FCM cloud bootstrap, no `firebaseConfig`, no cloud relay.
- No BlueBubbles `/api/v1/*` route shapes, response envelopes, or `status` codes.
- No private-API helper endpoints (typing indicators, reactions, edits, unsend,
  read-receipt writes, group renames, etc.).
- No Electron/Server admin UI endpoints.

A micaGO client targets **this** contract directly. Compatibility shims for
other servers are explicitly rejected (see
[`micago-feature-decision-matrix.md`](micago-feature-decision-matrix.md)).

## Versioning & stability guarantees

- **Contract version:** `0.9.0`. The running server reports its own version via
  `GET /api/server/info` (`version` field).
- **Additive-only within 0.x:** new optional fields and new endpoints may be
  added without a major bump. Clients **must ignore unknown JSON fields**.
- **Breaking changes** (renaming/removing a field, changing a type, changing an
  error `code`) require a new spec version (`spec-v0.10.0-*` or later) and a
  server `version` bump.
- **Field presence:** a field documented as nullable may be `null` or omitted as
  `null` in JSON; clients must treat "absent" and "null" identically. Non-nullable
  fields are always present.

## Conventions

| Concern | Rule |
| --- | --- |
| Transport | HTTP/1.1, JSON request/response unless noted (attachments stream bytes). |
| Base path | All REST endpoints live under `/api`. WebSocket is `/ws`. |
| JSON casing | `camelCase` for every field. |
| Timestamps | **Unix epoch milliseconds, UTC**, as JSON numbers. Apple Core Data epoch is converted server-side. Nullable timestamps are `null` when unknown/unset. |
| IDs / GUIDs | Opaque strings. Clients must not parse chat/message GUID structure. |
| Content-Type | Requests with a body send `application/json`. Responses are `application/json` except `GET /api/attachments/{guid}`. |
| Auth | Bearer token (see below). |
| Character encoding | UTF-8. |

### Authentication

A single shared Bearer token guards every endpoint **except** `GET /api/health`.

- REST: `Authorization: Bearer <token>`.
- WebSocket: either `Authorization: Bearer <token>` **or** a `?token=<token>`
  query parameter (browsers cannot set WebSocket headers).
- Missing/incorrect token → `401` with the standard error envelope.
- Auth may be disabled server-side for localhost development
  (`--disable-auth`); in that mode the token is not required. Clients should
  always send it anyway.

Token comparison is constant-time. See
[`spec-v0.6.0-security.md`](spec-v0.6.0-security.md).

### Error envelope

Every non-2xx JSON response uses this shape:

```json
{
  "error": {
    "code": "bad_request",
    "message": "limit must be between 1 and 500"
  }
}
```

`code` is a stable machine-readable string; `message` is human-readable and may
change. Clients branch on `code`, never on `message`.

| HTTP | `code` | Meaning |
| --- | --- | --- |
| 400 | `bad_request` | Invalid query param, body, or unsupported chat for send. |
| 400 | `push_not_configured` | Test push requested but push not configured for the device. |
| 401 | `unauthorized` | Missing/invalid Bearer token. |
| 404 | `not_found` | Chat, attachment, or device does not exist. |
| 409 | `conflict` | `tempGuid` already pending (duplicate send). |
| 500 | `internal_error` | Unexpected server error. |
| 500 | `send_failed` | AppleScript send failed or request canceled. |
| 501 | `not_implemented` | Notification provider not implemented (stub). |
| 504 | `send_confirmation_timeout` | AppleScript completed but no matching outgoing row appeared in `chat.db` before the confirmation timeout (15s). Carries a `details` object: `{tempGuid, chatGuid, text}`. (Renamed from `send_timeout` in v0.12.0.) |

### Pagination

List endpoints accept `limit` and `offset` and return a `meta` object echoing
them. There is no cursor token and no `totalCount`.

| Param | Type | Default | Constraints |
| --- | --- | --- | --- |
| `limit` | int | `100` | `1`–`500` inclusive |
| `offset` | int | `0` | `>= 0` |

Out-of-range values → `400 bad_request`.

---

## JSON models

These mirror the Go structs in `internal/store/models.go` and the notification
payload in `internal/notify/payload.go`. They are the canonical Mica-native
models.

### `Health`

```json
{ "ok": true }
```

### `ServerInfo`

```json
{
  "name": "MicaGoServer",
  "version": "0.8.0",
  "baseUrl": "http://127.0.0.1:3000",
  "websocketUrl": "ws://127.0.0.1:3000/ws",
  "features": {
    "chats": true,
    "messages": true,
    "sendText": true,
    "attachments": true,
    "websocket": true,
    "devices": true,
    "notifications": true
  },
  "notificationProviders": ["none", "webhook", "fcm", "hms", "ntfy"]
}
```

- `baseUrl` / `websocketUrl` may be empty strings if the server cannot derive
  them; clients should fall back to the origin they connected to.
- `features.*` are capability flags. Clients should feature-detect rather than
  assume. (`version` may lag this contract version until the server is bumped.)
- `notificationProviders` lists providers this server build accepts at
  registration time.

### `Handle`

```json
{ "id": "+15551234567", "service": "iMessage" }
```

| Field | Type | Notes |
| --- | --- | --- |
| `id` | string | Phone number or email of the remote handle. |
| `service` | string \| null | `iMessage`, `SMS`, `RCS`, or null. |

### `Attachment`

```json
{
  "guid": "AT-...",
  "filename": "IMG_0001.HEIC",
  "mimeType": "image/heic",
  "transferName": "IMG_0001.HEIC",
  "totalBytes": 1048576,
  "downloadUrl": "http://127.0.0.1:3000/api/attachments/AT-...",
  "uti": "public.heic",
  "isSticker": false,
  "attachmentKind": "image",
  "isVoiceMessage": false
}
```

| Field | Type | Notes |
| --- | --- | --- |
| `guid` | string | Attachment identifier; use in the download URL. |
| `filename` | string \| null | Stored filename. |
| `mimeType` | string \| null | Best-known MIME type; may be null. Since v0.11.5, filled by UTI/extension inference when chat.db has none. |
| `transferName` | string \| null | Display/transfer name. |
| `totalBytes` | int | Declared size; `0` if unknown. |
| `downloadUrl` | string | Absolute URL to fetch the bytes (Bearer required). |
| `uti` | string \| null | *(v0.11.5, additive)* Apple Uniform Type Identifier from chat.db. |
| `isSticker` | bool | *(v0.11.5, additive)* True for sticker attachments. |
| `attachmentKind` | string | *(v0.11.5, additive)* Coarse class: `image`/`video`/`audio`/`file`/`sticker`/`unknown`. Advisory; inspect `mimeType`/`uti` for precision. |
| `isVoiceMessage` | bool | *(v0.11.5, additive)* True only for the iMessage voice-memo container (CAF). A user-attached `.mp3`/`.m4a` is `audio` but not a voice message. |

> **Backward compatibility:** the v0.11.5 fields are purely additive. Clients
> built against earlier contracts ignore the extra keys.

### `Chat`

```json
{
  "guid": "iMessage;-;+15551234567",
  "chatIdentifier": "+15551234567",
  "serviceName": "iMessage",
  "displayName": "Family",
  "isArchived": false
}
```

| Field | Type | Notes |
| --- | --- | --- |
| `guid` | string | Stable chat identifier. Used in path params. |
| `chatIdentifier` | string \| null | Address/handle or group identifier. |
| `serviceName` | string \| null | `iMessage`, `SMS`, `RCS`, or null. |
| `displayName` | string \| null | Group display name; null for 1:1 chats. |
| `isArchived` | bool | Archived flag. |

### `Message`

```json
{
  "guid": "p:0/ABC-123",
  "text": "Hello",
  "subject": null,
  "service": "iMessage",
  "dateCreated": 1717372800000,
  "dateRead": null,
  "dateDelivered": 1717372801000,
  "isFromMe": false,
  "isRead": false,
  "isDelivered": true,
  "handle": { "id": "+15551234567", "service": "iMessage" },
  "cacheHasAttachments": false,
  "attachments": []
}
```

| Field | Type | Notes |
| --- | --- | --- |
| `guid` | string | Message identifier. |
| `text` | string \| null | Extracted body text (see [`spec-v0.3.1-text-extraction-fix.md`](spec-v0.3.1-text-extraction-fix.md)); null for attachment-only/empty messages. |
| `subject` | string \| null | Optional subject line. |
| `service` | string \| null | `iMessage`, `SMS`, `RCS`, or null. |
| `dateCreated` | int \| null | Unix ms. |
| `dateRead` | int \| null | Unix ms; null if unread/unknown. |
| `dateDelivered` | int \| null | Unix ms; null if not delivered/unknown. |
| `isFromMe` | bool | Outgoing flag. |
| `isRead` | bool | Read flag. |
| `isDelivered` | bool | Delivered flag. |
| `handle` | `Handle` \| null | Remote party; null for some outgoing/system rows. |
| `cacheHasAttachments` | bool | True if the source row flags attachments. |
| `attachments` | `Attachment[]` | Possibly empty; never null. |

### `Device`

```json
{
  "id": "9f1c...e2",
  "name": "Pixel 9",
  "platform": "android",
  "clientType": "flutter",
  "pushProvider": "fcm",
  "pushEnabled": true,
  "pushTokenSet": true,
  "lastSeenAt": 1717372800000,
  "createdAt": 1717000000000,
  "updatedAt": 1717372800000
}
```

| Field | Type | Notes |
| --- | --- | --- |
| `id` | string | Server-assigned (hex) if omitted at registration; otherwise client-supplied. |
| `name` | string | Required, human-readable. |
| `platform` | enum | `windows` \| `android` \| `ios` \| `harmonyos` \| `web` \| `unknown`. |
| `clientType` | enum | `tauri` \| `flutter` \| `web` \| `native` \| `unknown`. |
| `pushProvider` | enum | `none` \| `webhook` \| `fcm` \| `hms` \| `harmony_push` \| `ntfy`. |
| `pushEnabled` | bool | Whether push delivery is requested. |
| `pushTokenSet` | bool | **Read-only.** True if a push token is stored. The raw token is never returned. |
| `lastSeenAt` | int \| null | Unix ms of last heartbeat/registration. |
| `createdAt` | int | Unix ms. |
| `updatedAt` | int | Unix ms. |

See [`spec-v0.7.0-device-registry.md`](spec-v0.7.0-device-registry.md) and
[`spec-v0.8.0-notification-provider.md`](spec-v0.8.0-notification-provider.md).

### List envelope

```json
{ "data": [ /* items */ ], "meta": { "limit": 100, "offset": 0 } }
```

Single-resource device responses use `{ "data": { /* Device */ } }`.
Device list responses use `{ "data": [ /* Device[] */ ] }` (no `meta`).

---

## REST endpoints

Path params are shown as `{guid}` / `{id}`. All require auth unless noted.

### Health & server

#### `GET /api/health` — **no auth**
→ `200 Health` `{ "ok": true }`. Use for liveness probes before authenticating.

#### `GET /api/server/info`
→ `200 ServerInfo`. Clients call this first to discover capabilities.

#### `POST /api/auth/check`
→ `200 Health` `{ "ok": true }` if the token is valid, else `401`. Body ignored.

### Messages

#### `GET /api/messages/recent`
Recent messages across all chats.

Query: `limit`, `offset`, `service`, `includeEmpty`.

| Param | Type | Default | Values |
| --- | --- | --- | --- |
| `service` | enum | `iMessage` | `iMessage` \| `SMS` \| `RCS` \| `all` |
| `includeEmpty` | bool | `false` | include rows whose `text` is null/empty |

→ `200` List envelope of `Message`.

#### `GET /api/chats/{guid}/messages`
Messages within one chat (newest-first ordering as stored).

Query: `limit`, `offset`, `includeEmpty`.

→ `200` List envelope of `Message`.
→ `404 not_found` if the chat GUID is unknown.

### Chats

#### `GET /api/chats`
Query: `limit`, `offset`, `service`, `withArchived`.

| Param | Type | Default | Values |
| --- | --- | --- | --- |
| `service` | enum | `iMessage` | `iMessage` \| `SMS` \| `RCS` \| `all` |
| `withArchived` | bool | `false` | include archived chats |

→ `200` List envelope of `Chat`.

### Send

#### `POST /api/chats/{guid}/send`
Send a text message to an **iMessage** chat. Synchronous: the server triggers
AppleScript, runs a relay sync, then polls the relay DB until the outgoing
message is confirmed (up to ~120s).

Request body:

```json
{ "tempGuid": "client-generated-id", "message": "Hello" }
```

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `tempGuid` | string | yes | Client-chosen idempotency/correlation key. Must be unique while pending. |
| `message` | string | yes | Non-empty after trimming. |

Responses:

- `200` → the confirmed `Message` object (top-level, **not** wrapped in `data`).
- `400 bad_request` → missing field, invalid JSON, or chat is not iMessage.
- `404 not_found` → unknown chat GUID.
- `409 conflict` → a send with the same `tempGuid` is already pending.
- `500 send_failed` → AppleScript failed or the request was canceled.
- `504 send_confirmation_timeout` → AppleScript completed but the matching
  outgoing row was not observed in `chat.db` before the 15s deadline. The error
  envelope includes `details: {tempGuid, chatGuid, text}`.

Clients should also subscribe to the WebSocket to receive `send:pending`,
`send:match`, and `send:error` for the same `tempGuid` (useful if the HTTP
request is dropped). See [`spec-v0.3.0-send.md`](spec-v0.3.0-send.md) and
[`spec-v0.12.0-reliable-send-pipeline.md`](spec-v0.12.0-reliable-send-pipeline.md).

### Attachments

#### `GET /api/attachments/{guid}` — **binary**
Streams the attachment bytes. **Not JSON.**

- `200` → raw bytes. `Content-Type` is the stored MIME type (or
  `application/octet-stream`); `Content-Disposition: attachment; filename=...`
  is set when a name is known. Supports range requests via `http.ServeContent`.
- `404 not_found` → unknown GUID, hidden attachment, or missing file on disk.

See [`spec-v0.5.0-attachments.md`](spec-v0.5.0-attachments.md).

### Devices

See [`spec-v0.7.0-device-registry.md`](spec-v0.7.0-device-registry.md).

#### `POST /api/devices/register`
Create or update (upsert) a device record.

Request body:

```json
{
  "id": "",
  "name": "Pixel 9",
  "platform": "android",
  "clientType": "flutter",
  "pushProvider": "fcm",
  "pushToken": "<provider-token>",
  "pushEnabled": true
}
```

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `id` | string | no | Omit/empty to have the server generate a hex id. Reusing an id updates that device. |
| `name` | string | yes | — |
| `platform` | enum | yes | See `Device.platform`. |
| `clientType` | enum | yes | See `Device.clientType`. |
| `pushProvider` | enum | yes | Must be one of the server's `notificationProviders` (plus `harmony_push`). |
| `pushToken` | string | conditional | Required when `pushEnabled` is true and `pushProvider` is not `none` (except `webhook` when the server has a configured webhook URL). Write-only; never returned. |
| `pushEnabled` | bool | no | Defaults to `false`. |

→ `200 { "data": Device }`. → `400 bad_request` on validation failure.

#### `GET /api/devices`
→ `200 { "data": Device[] }`.

#### `PATCH /api/devices/{id}`
Partial update. Only present fields change. Body fields are all optional and
nullable-aware:

```json
{ "name": "...", "pushProvider": "...", "pushToken": "...", "pushEnabled": true }
```

→ `200 { "data": Device }`. → `404 not_found` if unknown. → `400 bad_request`
if the resulting record is invalid.

#### `POST /api/devices/{id}/heartbeat`
Marks the device seen now (updates `lastSeenAt`).
→ `200 { "data": Device }`. → `404 not_found`.

#### `DELETE /api/devices/{id}`
→ `200 Health` `{ "ok": true }`. → `404 not_found`.

#### `POST /api/devices/{id}/test-push`
Sends a test notification through the device's configured provider.

- `200 Health` `{ "ok": true }` on success.
- `400 push_not_configured` if push is disabled/`none` for the device.
- `501 not_implemented` if the provider is a stub (e.g. `fcm`, `hms`, `ntfy`).
- `404 not_found` if unknown.

---

## WebSocket protocol

### `GET /ws`

Upgrades to a plain WebSocket (no Socket.IO). Auth via `Authorization: Bearer`
header or `?token=` query param. Multiple concurrent clients are supported;
server shutdown closes connections cleanly.

The connection is **server → client push only**. Any frames a client sends are
read and discarded (they do not control the server). There is no
replay/backfill over the socket; clients backfill via the REST list endpoints,
then keep live via the socket. Realtime latency follows the sync interval (no
file watching on `chat.db`).

### Event envelope

Every frame is a JSON text message:

```json
{ "type": "message:new", "data": { } }
```

### Event types

#### `message:new`
`data` is a full `Message` object. Emitted once per newly inserted relay row
during a sync run (incoming or outgoing).

#### `send:pending`
Emitted right after a send request is accepted and its pending record is
created (before AppleScript runs). Lets async clients show an optimistic
"sending" state. Always followed by a `send:match` or `send:error` for the same
`tempGuid`.

```json
{
  "type": "send:pending",
  "data": { "tempGuid": "client-generated-id", "chatGuid": "iMessage;-;+15551234567" }
}
```

#### `send:match`
Emitted when a pending send is confirmed against the database.

```json
{
  "type": "send:match",
  "data": { "tempGuid": "client-generated-id", "message": { /* Message */ } }
}
```

#### `send:error`
Emitted when an AppleScript send fails or confirmation times out.

```json
{
  "type": "send:error",
  "data": {
    "tempGuid": "client-generated-id",
    "chatGuid": "iMessage;-;+15551234567",
    "code": "send_confirmation_timeout",
    "message": "AppleScript completed but no matching outgoing message appeared in chat.db before the confirmation timeout",
    "text": "hello world"
  }
}
```

`code` matches the REST send error codes (`send_failed`, `send_error`,
`messages_app_not_running`, `send_confirmation_timeout`). The timeout event
additionally carries `text` (the original message body).

#### `sync:error`
Emitted when a non-startup periodic sync run fails.

```json
{ "type": "sync:error", "data": { "message": "periodic sync failed" } }
```

Clients should treat unknown `type` values as ignorable (forward-compatibility).

See [`spec-v0.4.0-websocket.md`](spec-v0.4.0-websocket.md).

---

## Appendix A — Push notification payload (provider-bound)

When a notification is delivered to an external provider (currently the
`webhook` provider POSTs this JSON; other providers are stubs), the payload is:

```json
{
  "type": "message:new",
  "messageGuid": "p:0/ABC-123",
  "chatGuid": "iMessage;-;+15551234567",
  "title": "New iMessage",
  "body": "Hello",
  "previewMode": "sender_and_text",
  "createdAt": 1717372800000
}
```

`type` is `message:new` for new-message pushes or `test` for the test-push
endpoint. `title`/`body` content depends on the server's `previewMode`
(`none` | `sender` | `sender_and_text`). This payload is the **server → push
provider** contract, distinct from the WebSocket and REST models above. See
[`spec-v0.8.0-notification-provider.md`](spec-v0.8.0-notification-provider.md).

## Appendix B — Endpoint summary

| Method | Path | Auth | Success | Response |
| --- | --- | --- | --- | --- |
| GET | `/api/health` | no | 200 | `Health` |
| GET | `/api/server/info` | yes | 200 | `ServerInfo` |
| POST | `/api/auth/check` | yes | 200 | `Health` |
| GET | `/api/messages/recent` | yes | 200 | List of `Message` |
| GET | `/api/chats` | yes | 200 | List of `Chat` |
| GET | `/api/chats/{guid}/messages` | yes | 200 | List of `Message` |
| POST | `/api/chats/{guid}/send` | yes | 200 | `Message` (unwrapped) |
| GET | `/api/attachments/{guid}` | yes | 200 | binary stream |
| POST | `/api/devices/register` | yes | 200 | `{ data: Device }` |
| GET | `/api/devices` | yes | 200 | `{ data: Device[] }` |
| PATCH | `/api/devices/{id}` | yes | 200 | `{ data: Device }` |
| POST | `/api/devices/{id}/heartbeat` | yes | 200 | `{ data: Device }` |
| DELETE | `/api/devices/{id}` | yes | 200 | `Health` |
| POST | `/api/devices/{id}/test-push` | yes | 200 | `Health` |
| GET | `/ws` | yes | 101 | WebSocket (event envelope) |
