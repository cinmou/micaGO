# Firebase privacy boundaries

micaGO is local-first. Firebase is used **only** for Android FCM push and the
optional public-URL discovery. These boundaries are enforced in the server.

## Data kept local to micaGO

- message content
- contacts / contact display names
- phone numbers
- bearer token
- attachments
- chat history
- the device registry
- sync rules / `relay.db` data

## What may transit Firebase

- **FCM push (transient delivery)**: a small `data` message with
  `type`, `messageGuid`, `chatGuid`, `title`, `body`, `previewMode`, `createdAt`.
  The body is length-capped and sent as transient delivery data.
- **Push token → Google FCM** as the delivery address. The local registry is kept
  in `relay.db`.
- **Public server URL** (only if you enable Firestore URL sync): the single
  `publicBaseUrl` string in `server/config`.

## Contacts

Contact display names from the companion (v0.11.4) are **local-only**. They are
used by the companion's in-memory cache for the local UI.

## Service account

The service-account JSON stays on the Mac at the path you choose. The companion
shows only the filename after import.

## Sync rules interaction (v0.11.3)

- A **sync-blocked** chat stays out of `relay.db` and out of push dispatch.
- A **push-muted** chat still appears over the local WebSocket and is skipped by
  push dispatch.
