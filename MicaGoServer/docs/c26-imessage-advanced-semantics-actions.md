# C26: iMessage Advanced Semantics and Actions

Backend version: `v0.26.0`

## Summary

C26 aligns micaGO's message semantics with the iMessage/BlueBubbles model without adding a third-party runtime dependency:

- sticker attachments (`attachment.is_sticker`) and associated sticker messages (`associated_message_type = 1000`) are exposed as sticker/media semantics instead of generic broken files;
- edited text/attachment messages remain normal renderable messages with `isEdited`/`dateEdited` state;
- empty edited residue and missing attachment rows are explicit non-bubble semantic states;
- retracted/unsent messages keep priority over edited residue;
- the client renders retracted, deleted, unavailable, and missing-attachment rows intentionally as system rows;
- long-press actions are capability-driven and no longer open the generic debug sheet by default.

## Advanced iMessage Actions

The server now exposes:

- `GET /api/messages/actions/capabilities`
- `POST /api/chats/{chatGuid}/messages/{messageGuid}/edit`
- `POST /api/chats/{chatGuid}/messages/{messageGuid}/retract`
- `DELETE /api/chats/{chatGuid}/messages/{messageGuid}`

These actions must be executed through Messages.app/IMCore. micaGO does not write `chat.db` to fake edit, undo-send, or delete, because that would not propagate a real iMessage change.

The Go backend calls a bundled micaGO IMCore helper when present next to the backend executable or in the app bundle Resources directory. Development builds may point `MICAGO_IMCORE_HELPER` at a local helper binary. Users are not required to install `imsg` or `imsgbridge`; missing helper support is reported as `unsupported`.

Action errors are normalized:

- `unsupported` (`501`): helper absent, Messages.app selector unavailable, or current macOS cannot perform the action;
- `expired` (`409`): iMessage edit/undo-send window is no longer valid;
- `not_allowed` (`409`): Messages.app refused the action for policy/account/state reasons;
- `not_found` (`404`): chat or message was not found;
- `action_failed` (`500`): unexpected helper/IMCore failure.

## Sticker Display

The server already carries `isSticker`, `attachmentKind`, and `displayKind`. C26 adds an explicit `sticker` message semantic for associated sticker rows and the Flutter client treats sticker attachments as visual media first. If the downloaded sticker payload is not image-decodable on the client, the UI falls back to the file card instead of crashing.

Sending stickers is out of scope for C26.

## LAN Endpoint Refresh

On backend startup, the server emits a best-effort `connection:updated` realtime event. The Flutter client also refreshes `/api/server/urls` after WebSocket connection, so Dashboard/Create Connection QR data is refreshed even if the client connects after the startup event.

Public/remote endpoints remain optional and are not required for LAN pairing.

## Limitations

Edit, undo-send, and delete are limited by Apple's Messages.app behavior and macOS private selector availability. If Messages.app cannot perform an action, micaGO returns a clear error and does not mutate local database rows as a substitute.
