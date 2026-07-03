# iMessage feature map (client roadmap)

Internal planning doc for the micaGO Android client. **Not** a user guide.
It maps iMessage-class features (inspired by **BlueBubbles** for capability
coverage and **FluffyChat** for native-messenger UX) to where micaGO stands
today, so we know what to build next and what needs server support first.

Legend:
- ✅ **Supported now** — works in the current client build.
- 🟡 **Server exists, client missing** — the micaGO server already exposes this; the client just needs UI/logic.
- 🔴 **Server missing** — the server does not expose this yet; needs server work first.
- ⏳ **Later** — planned, not scheduled for the current phases.

| Feature | Status | Notes |
| --- | --- | --- |
| Server/connection pairing | ✅ | Manual form + **QR pairing** (C1). Bearer token stored securely. |
| Chat list | 🟡→✅ (partial) | `GET /api/chats` returns `guid, chatIdentifier, serviceName, displayName, isArchived`. Client lists them (C1). **No** last-message/timestamp/unread/participants from the server yet — see gaps below. |
| Text messages (history) | ✅ (C2) | `GET /api/chats/{guid}/messages` rendered in a real Material thread (server returns newest-first; client reverses to chronological, scrolls to bottom). |
| Send text | ✅ (C2) | `POST /api/chats/{guid}/send` with optimistic pending bubble; confirmed by the synchronous HTTP response and/or `send:match` (by `tempGuid`); `send:error` → failed + tap-to-retry. |
| Realtime updates | ✅ (C2) | WS events parsed to a typed stream. `send:match`/`send:error` update the matching optimistic message by `tempGuid`. `message:new`/`update`/`unsend` → debounced thread reload (see gap: no chatGuid on payload). |
| Delivered status | ✅ (C2, display) | `Message.isDelivered`/`isRead` shown as "Delivered"/"Read" on outgoing bubbles. |
| Read receipts | 🟡 | Read state displayed; **sending** read receipts is out of scope (no private-API writes). |
| Image display | ✅ (C2) | Fetched via authenticated `GET /api/attachments/{guid}` (bytes, token in header), thumbnail + full-screen viewer. |
| Audio / voice display | ✅ (C2) | `just_audio` streams `GET /api/attachments/{guid}` with the bearer header (token not in URL); play/pause row; voice memos labelled. |
| File display | ✅ (C2) | Name + size + type icon. Open/download ⏳. |
| Image / audio / file **sending** | 🔴 (server) | **No media-send endpoint** — `POST /api/chats/{guid}/send` accepts text only. Composer attachment button is disabled with a "not supported by this server yet" tooltip. |
| Contacts matching / handle merging | ✅ (C2, client-local) | Read-only `flutter_contacts`, on-demand `READ_CONTACTS`. Local index merges phone/email handles → one display name; improves chat list, thread sender, People tab. Never uploaded. |
| Group chats | 🟡 | Server distinguishes groups via `displayName`; no participant list yet. Client uses a heuristic group indicator + shows sender name in incoming group bubbles. |
| Avatars | 🟡 | Initials/placeholder avatars. Contact photos ⏳ (local-only if added). |
| Tapbacks / reactions | 🔴 | `associated_message_*` is read-only on the server side and not surfaced to clients; **sending** reactions is explicitly out of scope (no private API). Display ⏳. |
| Replies (threaded) | 🔴 | Reply metadata not exposed by the API yet. ⏳ |
| Stickers | 🔴 | Sticker attachments flagged server-side (`isSticker`) but not yet a client feature. ⏳ |
| Message edit | 🔴/⏳ | Server can *detect* edited messages (schema capability) and emits `message:update`; **editing** from the client is out of scope (no private-API writes). |
| Unsend / retract | 🔴/⏳ | Server detects retractions (`message:unsend`); initiating unsend is out of scope. |
| Typing indicators | 🔴 | Not exposed by the server. ⏳ |
| Expressive/screen effects | 🔴 | Effect metadata deferred server-side; display ⏳. Sending effects is out of scope. |
| Scheduled sending | 🔴 (server) | Planned server milestone (v0.13). Client ⏳ if/when the server supports it. |
| Notifications / push | 🟡 | Server has FCM self-host (v0.12). Client push is **intentionally deferred** until pairing/REST/WS/list/send basics are stable. |
| Multi-device sessions | 🟡 | Server device registry exists (`/api/devices`). Client multi-device session management ⏳. |

## Known server API gaps discovered (C1)

The chat-list endpoint is intentionally minimal. For a polished chat list we
will eventually want the server `Chat` object (or a dedicated list endpoint) to
include:

- **last message preview** (text/snippet) and **timestamp**,
- **unread count**,
- **participants** (handles/names) for group avatars & titles,
- **pinned / muted** flags,
- an explicit **isGroup** flag (currently inferred from `displayName`).

Until then the client model (`ChatSummary`) carries these as **optional** fields
and the UI falls back gracefully (service/identifier subtitle, initials avatar,
no timestamp/unread when absent).

## Known server API gaps discovered (C2)

- **No chat GUID on realtime message events.** `message:new` / `message:update`
  / `message:unsend` payloads carry the `Message` (or guid) but **not** the chat
  it belongs to, so a client can't route an incoming message to a specific open
  thread. Fallback: the open thread does a **debounced reload** on these events.
  `send:match`/`send:error` are precise (they carry our `tempGuid`).
- **No media-send endpoint.** `POST /api/chats/{guid}/send` is text-only; there
  is no attachment upload route. Media **display** works (download endpoint);
  media **sending** is unsupported (composer attachment button disabled).
- **No reactions/replies in `Message`.** `associated_message_*` / reply
  relations aren't surfaced, so the client keeps empty model placeholders
  (`reactions`, `replyToGuid`) and renders nothing for them yet.
- **No contact names from the server** (by design — privacy). The client matches
  handles to names **locally** via read-only device contacts; nothing is sent to
  the server.

## Personalization / localization status (C2.5)

- **Theming:** ✅ Material 3 with Android 12+ **dynamic color** (Material You) by
  default (`dynamic_color`), plus a seed-color picker (micaGO + presets) and
  light/dark/system theme mode. Persisted locally.
- **Localization:** 🟡 **architecture only.** The Settings UI offers System /
  English / 简体中文 and the app sets `locale` + `flutter_localizations`
  delegates, so **built-in Material/Cupertino widgets** localize. **App-specific
  strings are not yet translated** — there are no ARB/intl message catalogs yet.
  Switching to Chinese will not translate micaGO's own labels until that work is
  done. (Do not fake translations.)

## C2.6 UX additions

- **History pagination:** ✅ load-older on scroll-to-top via `limit`/`offset`
  (server has **no cursor**), deduped by GUID, in a reversed list so scroll
  position is preserved. *Gap:* offset paging can skew if many messages arrive
  mid-scroll — a server cursor would fix this.
- **Two-pane / tablet layout:** ✅ phone = single pane (push thread); wide
  (≥720dp) = list + detail split with empty state; selection survives resize.
- **Avatars:** ✅ deterministic colored initials (chat list, thread header, group
  senders). Contact **photos** deferred — `flutter_contacts` 2.2.1 has no cheap
  bulk thumbnail fetch.
- **Date separators + delivery/read** shown from `dateCreated`/`isDelivered`/
  `isRead`; outgoing states Sending / Delivered / Read / Failed‑tap‑to‑retry.

## Non-goals (carried from the server's guardrails)

No private-API writes: the client will **not** send tapbacks, edits, unsends,
typing, read receipts, or effects. micaGO mirrors and sends plain text/media via
the supported server endpoints only.
