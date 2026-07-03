# Firebase privacy boundaries

micaGO is local-first. Firebase is used **only** for Android FCM push and the
optional public-URL discovery. These boundaries are enforced in the server.

## Never stored in Firebase (Firestore or anywhere in your project)

- ❌ message content
- ❌ contacts / contact display names
- ❌ phone numbers
- ❌ bearer token
- ❌ push tokens in any public/world-readable document
- ❌ attachments
- ❌ chat history
- ❌ the device registry
- ❌ sync rules / `relay.db` data

## What may transit Firebase

- ✅ **FCM push (transient delivery, not storage)**: a small `data` message with
  `type`, `messageGuid`, `chatGuid`, `title`, `body`, `previewMode`, `createdAt`.
  The `title`/`body` text is gated by your **Preview** setting:
  - `none` → generic "New iMessage", **no sender, no text**;
  - `sender` → sender label only;
  - `sender_and_text` → sender + message text (only because you explicitly chose
    this level). The body is length-capped and sent as a transient push — it is
    **never stored** in Firestore or persisted server-side beyond `relay.db`.
- ✅ **Push token → Google FCM** as the delivery address (that is its purpose).
  Stored only locally in `relay.db`; never published in a Firestore document.
- ✅ **Public server URL** (only if you enable Firestore URL sync): the single
  `publicBaseUrl` string in `server/config`. No token, no content.

## Contacts

Contact display names from the companion (v0.11.4) are **local-only**. They are
**never** uploaded to Firebase, included in any FCM payload, or sent to the
server. They exist only in the companion's in-memory cache for the local UI.

## Service account

The service-account JSON stays on the Mac at the path you choose. It is never
returned by any API, never logged, and never sent to clients. The companion
shows only the filename after import.

## Sync rules interaction (v0.11.3)

- A **sync-blocked** chat is never written to `relay.db`, so it can never push.
- A **push-muted** (but synced) chat appears over the local WebSocket but is
  **excluded from push dispatch** — no FCM message is sent for it.
