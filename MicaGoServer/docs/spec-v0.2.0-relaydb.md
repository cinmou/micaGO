# Mica v0.2.0 Relay DB Spec

> Current status: this is the original bootstrap spec for `relay.db`. The live
> implementation has grown beyond it: `relay.db` now stores the rebuildable
> message/chat/attachment cache **and** micaGO-owned local state such as paired
> devices, push tokens, sync settings, privacy rules, and message-state
> fingerprints. The message cache can be regenerated from `chat.db`; the whole
> database should not be treated as disposable unless the user is intentionally
> resetting pairing and settings.

## Goal

Mica v0.2.0 adds a lightweight local relay database that stores a clean iMessage-only subset of macOS Messages data copied from `~/Library/Messages/chat.db`.

This milestone is intentionally limited to:

- bootstrap `relay.db`
- create the minimal schema
- run a one-way sync skeleton
- copy a clean iMessage view only

This milestone does not implement sending, WebSocket, auth, frontend, Firebase, push notifications, Private API, or attachment download.

## Current Design Rationale

micaGO does not cache Apple data because `chat.db` is hard to query. It caches a
small, normalized projection because the product needs a stable boundary between
Apple's private database and first-party clients.

The relay database provides:

- a durable change journal for client delta sync: `chat.db` has no updated-at
  column or change log, so an offline client's "everything since cursor X" —
  including read/delivered/edit state changes on old rows — can only be
  answered from micaGO's own store;
- a read-only boundary: micaGO never writes to or repairs Apple's `chat.db`;
- stable API fields even when macOS changes `chat.db` columns;
- deterministic pagination and indexing for chat lists, threads, deltas, and
  attachment lookup;
- durable deduplication for realtime events and send confirmation;
- a place for micaGO-owned local state that Apple does not store, including
  device registration, push tokens, sync settings, and privacy rules;
- offline/cached reads when a startup sync fails temporarily and later retries.

Directly serving every client request from `chat.db` would remove one SQLite
file, but it would make API latency, pagination, realtime dedupe, and schema
compatibility depend on Apple's live database shape. It would also force
micaGO-owned state into a separate database anyway. The current design keeps
Apple's database as the source of truth while using `relay.db` as the product's
local, controlled projection.

## Relay DB Path

Default path:

```text
~/.micago/relay.db
```

Resolved path:

```text
filepath.Join(os.Getenv("HOME"), ".micago", "relay.db")
```

## Schema

### chats

- `guid TEXT PRIMARY KEY`
- `chat_identifier TEXT`
- `service_name TEXT`
- `display_name TEXT`
- `is_archived INTEGER`
- `updated_at INTEGER`

### messages

- `guid TEXT PRIMARY KEY`
- `chat_guid TEXT`
- `text TEXT`
- `subject TEXT`
- `service TEXT`
- `date_created INTEGER`
- `date_read INTEGER`
- `date_delivered INTEGER`
- `is_from_me INTEGER`
- `is_read INTEGER`
- `is_delivered INTEGER`
- `handle_id TEXT`
- `handle_service TEXT`
- `cache_has_attachments INTEGER`
- `created_at INTEGER`

### sync_state

- `key TEXT PRIMARY KEY`
- `value TEXT`

## Sync Behavior

The initial sync is a one-way copy:

- source: `~/Library/Messages/chat.db`
- destination: `~/.micago/relay.db`

Rules:

- chats are copied with `service_name = 'iMessage'`
- messages are copied with:
  - chat-level `service=iMessage` via joined `chat.service_name = 'iMessage'`
  - `includeEmpty = false`
  - `(message.text IS NOT NULL OR message.cache_has_attachments = 1)`
- initial sync copies the latest `1000` messages by default
- sync uses upserts (write-avoiding; see below)
- sync does not delete old relay rows yet

### Write avoidance (C57)

Steady-state syncs are read-mostly; caching `chat.db` does not mean rewriting
it every cycle:

- every sync upsert (chats, messages, attachments) carries a
  `DO UPDATE ... WHERE <column diff>`, so a re-scanned row whose values are
  unchanged is skipped entirely — no row rewrite, no WAL churn, and
  `chats.updated_at` only moves on a real content change;
- `attachments.created_at` is insert-only (rows without a source timestamp used
  a `now` fallback that moved on every pass, which also destabilized the
  `(created_at, guid)` attachment-dedup ordering);
- the per-message existence probe is one chunked `IN` query per batch instead
  of a `SELECT` per row;
- the date-lookback recovery scan (C11) is throttled at the app level to once
  per minute (re-armed if the consuming sync fails). The ROWID watermark stays
  the per-sync new-message path, and the update pass (read receipts / edits)
  keeps its full cadence.

Each sync reports written vs unchanged row counts and whether the lookback scan
ran; they surface in the status diagnostics as `lastChatsWritten`,
`lastMessagesWritten`, `lastAttachmentsWritten`, `lastRowsUnchanged`, and
`lastLookbackApplied`.

## What Data Is Copied

Copied chat fields:

- `guid`
- `chat_identifier`
- `service_name`
- `display_name`
- `is_archived`

Copied message fields:

- `guid`
- `chat_guid`
- `text`
- `subject`
- `service`
- `date_created`
- `date_read`
- `date_delivered`
- `is_from_me`
- `is_read`
- `is_delivered`
- `handle_id`
- `handle_service`
- `cache_has_attachments`

Copied sync metadata:

- last sync timestamp
- last synced message guid
- last synced message timestamp

## What Is Deliberately Not Copied

- non-iMessage chats by default
- empty non-attachment messages
- attachment binary data
- attachment tables or download state
- reactions
- edits / unsends
- reply metadata
- rich attributed body structures
- BlueBubbles private API state
- relay-side deletes or tombstones

## Manual Test Steps

From `micago-server/`:

```bash
go test ./...
go run ./cmd/micago --sync-once
sqlite3 ~/.micago/relay.db '.tables'
sqlite3 ~/.micago/relay.db 'SELECT COUNT(*) FROM chats;'
sqlite3 ~/.micago/relay.db 'SELECT COUNT(*) FROM messages;'
sqlite3 ~/.micago/relay.db 'SELECT key, value FROM sync_state ORDER BY key;'
sqlite3 ~/.micago/relay.db 'SELECT guid, service_name, is_archived FROM chats ORDER BY updated_at DESC LIMIT 10;'
sqlite3 ~/.micago/relay.db 'SELECT guid, chat_guid, text, date_created FROM messages ORDER BY date_created DESC LIMIT 10;'
```

Expected checks:

- `relay.db` is created under `~/.micago/`
- `chats`, `messages`, and `sync_state` tables exist
- chats are iMessage-only
- messages are iMessage-only and exclude empty non-attachment messages
- repeated `--sync-once` runs do not duplicate rows

## Completion Criteria

- `~/.micago/relay.db` is created automatically if missing
- migrations create the expected tables
- `go run ./cmd/micago --sync-once` performs a one-way sync and exits
- initial sync upserts iMessage chats and the latest 1000 clean iMessage messages
- sync writes sync metadata to `sync_state`
- logs show relay.db path, synced chat count, synced message count, and the last synced message guid or date
- `go test ./...` passes
