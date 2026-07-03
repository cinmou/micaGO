# spec-v0.11.5 — Message Fidelity Patch

Status: **Implemented (server)**. A focused, conservative, **additive** patch to
improve attachment fidelity and fix a text-extraction bug, done *before* v0.12
Firebase push (push surfaces message text/attachments, so they should be correct
first). No private-API sending, no BlueBubbles API/Socket.IO shapes, no effect
*sending*.

---

## 1. BlueBubbles source audit (reference only)

Files inspected (under
`MicaGoServer/bluebubbles server/packages/server/src/server/`):

| File | What it told us |
| --- | --- |
| `databases/imessage/entity/Attachment.ts` | Attachment columns: `guid, created_date, filename`(→filePath)`, uti, mime_type, transfer_state, is_outgoing, user_info, transfer_name, total_bytes, is_sticker`(Sierra+)`, sticker_user_info, attribution_info, hide_attachment, original_guid`. `getMimeType()` = `mime_type ?? user_info['mime-type'] ?? mime.lookup(path) ?? "application/octet-stream"`. Dimensions come from `attribution_info[0].pgensw/pgensh`. |
| `api/serializers/AttachmentSerializer.ts` | Exposes `uti, mimeType, transferName, totalBytes` (+ `transferState, isOutgoing, hideAttachment, isSticker, originalGuid, hasLivePhoto, metadata`). Conversions are applied at serialize time via `convertImage`/`convertAudio`. |
| `databases/imessage/helpers/utils.ts` | **HEIC/HEIF/TIFF → JPEG** (`convertImage`) and **CAF → MP3** (`convertAudio`, gated on `uti === "com.apple.coreaudio-format"` or `mime == "audio/x-caf"`). `getAttachmentMetadata` branches on `uti == coreaudio-format` / `mime.startsWith("audio"|"image")`. Conversions write into a `convertDir` and mutate the served `mimeType`/`filePath`. |
| `databases/imessage/entity/Message.ts` | Effect/extra columns: **`is_audio_message`**, `item_type`, `group_action_type`, `associated_message_guid`, `associated_message_type`, **`balloon_bundle_id`** (HighSierra+), `payload_data`, **`expressive_send_style_id`** (HighSierra+). `universalText(sanitize)` = `text ?? AttributedBodyUtils.extractText(attributedBody)`, optionally `sanitizeStr`'d. |
| `databases/imessage/entity/decoders/MessageDecoder.ts` | Confirms `is_audio_message` maps to `message_is_audio_message`. |
| `utils/AttributedBodyUtils.ts` | `extractText` simply returns the first `.string` of the decoded typedstream object — the heavy lifting is `node-typedstream`. |
| `helpers/utils.ts` (`sanitizeStr`) + `api/http/constants.ts` | `sanitizeStr` only strips the **invisible** Object-Replacement char `U+FFFC` (`String.fromCharCode(65532)`). It does **not** touch `+!`/`+$`. |

### The `+!` / `+$` prefix question (answered)

`+!`/`+$` are **not** anything BlueBubbles strips — BlueBubbles never has them,
because it decodes the typedstream *structurally* (via `node-typedstream`) and
reads the string's declared length. The prefixes are an artifact of a **naive
byte-scan** extractor (which micaGO used). In Apple's typedstream encoding an
`NSString`'s bytes are written as:

```
… "NSString" 01 94 84 01 2B <len> <utf8 bytes …>
                          ^^  ^^^^^
                          '+'  length prefix (typedstream int)
```

The byte right after the `+` (`0x2b`) marker is the **string length**. For
string lengths **32–126** that length byte is itself a printable ASCII char
(33 = `0x21` = `!`, 36 = `0x24` = `$`, …), so a scanner that only skips the
length byte *when it is non-printable* leaks `+` + the length char as a visible
prefix. Lengths ≥ 128 use `0x81` + uint16(LE) (and the old code happened to work
for those because `0x81` is non-printable).

---

## 2. micaGO current state (before this patch)

- **chat.db read** (`internal/store/queries.go`, `attachmentBaseSelect`) selected
  `guid, mime_type, transfer_name, total_bytes, filename(local_path), is_outgoing,
  hide_attachment, created_date` — **no `uti`, no `is_sticker`**.
- **relay.db** (`internal/relaydb/migrations.go`) `attachments` table had the same
  columns — no `uti`/`is_sticker`.
- **API/WS model** (`internal/store/models.go`, `AttachmentJSON`): `guid, filename,
  mimeType, transferName, totalBytes, downloadUrl`. No kind/voice/uti.
- **Download** (`internal/httpapi/handlers.go`, `GetAttachment`): safe path
  resolution (`resolveAttachmentPath` = `EvalSymlinks` + root-prefix check),
  `hideAttachment` respected, range support via `http.ServeContent`. `Content-Type`
  used the stored MIME or `application/octet-stream` — **no inference**.
- **Text** (`internal/store/text.go`, `decodeAttributedBodyText`): byte-scan
  extractor with the `+!`/`+$` leak described above.

---

## 3. What this patch changes (confirmed, implemented)

All new model fields are **additive and nullable/defaulted** — pre-v0.11.5
clients simply ignore them (per the v0.9 contract). No fields were removed; raw
`mimeType`/`transferName`/`filename` are all preserved.

### 3a. Text extraction fix (`internal/store/text.go`)

`decodeNSStringPayload` now **parses the typedstream length prefix** after the
`+` marker (single byte; `0x81`+uint16; `0x82`+uint32) and slices exactly that
many UTF-8 bytes. Falls back to the old printable-run heuristic only when the
length-prefixed parse fails. This removes the `+!`/`+$` prefixes for all message
lengths while preserving existing behavior for short/long strings and emoji.

### 3b. Attachment kind / voice / MIME inference (`internal/store/attachmentkind.go`, new)

- `AttachmentKind(isSticker, mime, uti, transferName, filename) → image | video | audio | file | sticker | unknown`.
- `IsVoiceMessage(uti, mime)` → true only for the canonical iMessage voice-memo
  container (`uti == com.apple.coreaudio-format` / `mime == audio/x-caf`). A
  user-attached `.mp3`/`.m4a` is `audio` but **not** a voice message.
- `InferMimeType(mime, uti, transferName, filename)` → stored MIME wins; else a
  small UTI→MIME table; else a deterministic extension table (then
  `mime.TypeByExtension`). Returns `nil` only when nothing is inferable.
- `DecorateAttachmentJSON(*AttachmentJSON)` fills the derived fields from the raw
  ones (only *filling in* an empty MIME, never overwriting a stored one).

### 3c. Plumbing `uti` + `is_sticker` end-to-end

- chat.db SELECT adds `a.uti, a.is_sticker` (consistent with the existing
  Sierra+ assumptions already made by `a.is_outgoing`/`a.hide_attachment`).
  `is_sticker` is scanned as `NULL`-safe.
- `store.SyncAttachmentRow` / `store.AttachmentMeta` gain `Uti *string`, `IsSticker bool`.
- relay.db migration adds `attachments.uti TEXT` and `attachments.is_sticker INTEGER`
  via the existing idempotent `ensureColumn` helper (safe on existing DBs).
- Sync upsert (`upsertAttachmentsTx`) writes the two new columns.
- Both relay.db read paths (`loadAttachmentsByMessageGUID`, `GetAttachmentByGUID`)
  and the live chat.db path (`attachMessageAttachments`) read them and call
  `DecorateAttachmentJSON`, so REST **and** WebSocket payloads carry the new fields.

### 3d. Download Content-Type (`internal/httpapi/handlers.go`)

`GetAttachment` now sets `Content-Type` from `store.InferMimeType(...)` (stored
MIME still wins), so HEIC/CAF/etc. with a null stored MIME but a known UTI/ext
download with a sensible type. **Safe path handling is unchanged.**

### New `AttachmentJSON` fields

```jsonc
{
  // …existing: guid, filename, mimeType, transferName, totalBytes, downloadUrl
  "uti": "public.heic",        // nullable
  "isSticker": false,
  "attachmentKind": "image",   // image|video|audio|file|sticker|unknown
  "isVoiceMessage": false
}
```

---

## 4. Deliberately deferred (not implemented this pass)

These are **safe to add later** but each multiplies the change surface (every
message SELECT + relay.db `messages` schema + sync upsert + `scanRelayMessages` +
`MessageJSON`), so they are out of scope for a "conservative patch only if
clearly justified" pass and are documented here instead.

1. **Message-level effect metadata** — read-only `expressiveSendStyleID`,
   `balloonBundleID`, and a derived `messageEffect`. Columns exist (HighSierra+);
   would need capability-gated SELECTs in the message pipeline + 2 nullable
   `messages` columns. *No effect **sending** will ever be added.*
2. **`isVoiceMessage` from `message.is_audio_message`.** We currently derive voice
   status from the attachment's CAF UTI, which is reliable for real voice memos.
   The message-level boolean is the BlueBubbles-authoritative signal but needs a
   `messages` column + message-SELECT change.
3. **Server-side HEIC→JPEG / CAF→MP3 conversion.** BlueBubbles converts on
   serialize. micaGO deliberately serves the **original** bytes with correct
   metadata (`uti`/`mimeType`/`attachmentKind`) and lets the client decide. This
   keeps the server dependency-free; revisit only if a target client can't decode
   HEIC/CAF.
4. **Thumbnails/previews & image dimensions** (`attribution_info` pgensw/pgensh).
   Not currently surfaced; additive if a client needs it.
5. **Tapbacks/associated messages** (`associated_message_guid/type`, `item_type`,
   `group_action_type`) and **group/system events** — already tracked under the
   deferred v0.11.x `chat:event` work; reading only, never sending.

---

## 5. Files changed

- `internal/store/text.go` — typedstream length-prefix fix; removed dead `isPrintableByte`.
- `internal/store/attachmentkind.go` *(new)* — kind/voice/MIME inference + `DecorateAttachmentJSON`.
- `internal/store/models.go` — `AttachmentJSON` (+4 fields), `SyncAttachmentRow`/`AttachmentMeta` (+`Uti`,`IsSticker`).
- `internal/store/queries.go` — SELECT `a.uti,a.is_sticker`; scan; decorate live path.
- `internal/relaydb/migrations.go` — `ensureColumn` `uti`,`is_sticker`.
- `internal/relaydb/sync.go` — upsert the two columns.
- `internal/relaydb/query.go` — read + decorate in both attachment read paths.
- `internal/httpapi/handlers.go` — `Content-Type` via `InferMimeType`.
- Tests: `internal/store/attachmentkind_test.go` *(new)*, `internal/store/text_test.go` (+prefix tests).

### Migrations

`attachments.uti TEXT`, `attachments.is_sticker INTEGER` — additive, idempotent,
safe on existing `relay.db` (existing rows backfill on next sync upsert).
