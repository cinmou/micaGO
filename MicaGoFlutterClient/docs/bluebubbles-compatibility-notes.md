# BlueBubbles compatibility notes

Semantic-compatibility audit and porting plan. We **read** BlueBubbles (BB) as
the reference for iMessage message semantics and **port the concepts** into
micaGO's own Go server + Flutter client — we do not copy code.

## 1. BlueBubbles server files inspected

- `packages/server/src/server/databases/imessage/entity/Message.ts` — the
  TypeORM `Message` entity: every chat.db column BB reads, plus derived getters
  (`isDigitalTouch`, `isHandwritten`, retract/edit helpers).
- `packages/server/src/server/api/serializers/MessageSerializer.ts` — the
  canonical `MessageResponse` JSON shape sent to clients.
- `packages/server/src/server/databases/transformers/MessageTypeTransformer.ts`
  — `associated_message_type` integer ⇄ reaction string mapping.
- `packages/server/src/server/databases/imessage/entity/{Attachment,Handle,Chat}.ts`,
  `helpers/utils.ts` — attachment/handle/chat fields.

## 2. BlueBubbles client files inspected

- `lib/database/io/message.dart` — client `Message` model + getters
  (`fullText`, reaction/effect handling).
- `lib/helpers/ui/reaction_helpers.dart` — `ReactionTypes` (love/like/dislike/
  laugh/emphasize/question), `reactionToVerb`, `reactionToEmoji`, and
  `getUniqueReactionMessages` (latest reaction per handle; `-` prefix = removed).
- `lib/helpers/types/constants.dart` — `effectMap` (expressive + screen effect
  bundle IDs), `balloonBundleIdMap`.
- `lib/helpers/types/helpers/message_helper.dart` — reaction/effect text.

### Key semantic facts learned

- **Reactions/tapbacks** use `associated_message_type` (INTEGER in chat.db; BB
  maps it to a string): `1000 sticker`, `2000 love`, `2001 like`, `2002 dislike`,
  `2003 laugh`, `2004 emphasize`, `2005 question`; `3000–3005` = the **removed**
  variants. `associated_message_guid` targets the message reacted to, formatted
  `p:<part>/<guid>` or `bp:<guid>` — the GUID must be parsed out of that prefix.
- **Replies** are a *separate* mechanism: `thread_originator_guid` (+
  `thread_originator_part`, `reply_to_guid`) points at the replied-to message.
  This is **not** `associated_message_guid`. (Our earlier debug heuristic
  conflated the two — corrected here.)
- **Effects** use `expressive_send_style_id`: `…expressivesend.impact` (Slam),
  `.loud`, `.gentle`, `.invisibleink`; screen effects `CKEchoEffect`,
  `CKSpotlightEffect`, `CKHappyBirthdayEffect` (balloons), `CKConfettiEffect`,
  `CKHeartEffect` (love), `CKLasersEffect`, `CKFireworksEffect`,
  `CKSparklesEffect` (celebration).
- **Unsent/edited** use `date_retracted` / `date_edited` (Ventura+).
- **Service/group events** use `item_type` + `group_action_type` + `group_title`.
- **Interactive balloons** use `balloon_bundle_id` (+ `payload_data`).

## 3. Field mapping table

`bb` = BlueBubbles `MessageResponse` field · `chat.db` = source column ·
`micago(before)` = field on micaGO `MessageJSON` before this phase ·
`micago(now)` = field after this phase · `client` = Flutter rendering behavior.

| bb | chat.db | micago(before) | micago(now) | client rendering |
| --- | --- | --- | --- | --- |
| guid | `guid` | `guid` | `guid` | message identity / dedupe |
| (chat guid) | `chat.guid` | — | `chatGuid` | route WS events to open thread |
| handle | `handle.id`/`service` | `handle{id,service}` | unchanged + `handleId` | sender resolution |
| isFromMe | `is_from_me` | `isFromMe` | `isFromMe` | bubble alignment, "You" |
| text/fullText/attributedBody | `text`/`attributedBody` | `text` (decoded) | `text` (decoded) | bubble body; control-like → hidden |
| attachments | join | `attachments[]` | `attachments[]` (+kind/uti/voice) | media views |
| associatedMessageType | `associated_message_type` (int) | — | `associatedMessageType` (int) | tapback chip (int→love/like/…) |
| associatedMessageGuid | `associated_message_guid` | — | `associatedMessageGuid` | attach reaction to target (parse `p:/bp:`) |
| (reply target) threadOriginatorGuid | `thread_originator_guid` | — | `threadOriginatorGuid` | reply preview above bubble |
| itemType | `item_type` | (parsed, unused) | `itemType` | service/system row |
| groupActionType | `group_action_type` | (parsed, unused) | `groupActionType` | group-event row |
| groupTitle | `group_title` | (parsed, unused) | `groupTitle` | "named the conversation…" |
| balloonBundleId | `balloon_bundle_id` | — | `balloonBundleId` | interactive/effect hint |
| expressiveSendStyleId | `expressive_send_style_id` | — | `expressiveSendStyleId` | "Sent with …" label |
| hasPayloadData | `payload_data` (blob) | — | `payloadDataPresent` (bool) | debug only |
| dateCreated | `date` | `dateCreated` | `dateCreated` | timestamp |
| dateDelivered | `date_delivered` | `dateDelivered` | `dateDelivered` | "Delivered" |
| dateRead | `date_read` | `dateRead` | `dateRead` | "Read" |
| dateRetracted | `date_retracted` | — | `dateRetracted` + `isRetracted` | "unsent" system row |
| dateEdited | `date_edited` | — | `dateEdited` + `isEdited` | "(edited)" marker |
| error | `error` | (debug only) | `error` | "Failed" / tap-retry |
| service | `service` | `service` | `service` | SMS/iMessage label |
| account | `account`/`account_guid` | — | (debug-only) | not rendered |
| cacheHasAttachments | `cache_has_attachments` | `cacheHasAttachments` | `cacheHasAttachments` | attachment-pending hint |

## 4. Client-only (no server change)

- Reaction → emoji/verb mapping and rendering as chips on the target bubble.
- Effect bundle-ID → human label ("Sent with Slam", …).
- Reply preview block (quoted sender + text) from the loaded target message.
- "This message was unsent" / "You unsent a message" system row styling.
- Delivery/read **visibility rules** (latest outgoing only; failed always).
- Display preferences: hide/merge system rows, merge tapbacks, effect-hint
  toggle, delivery-label verbosity, debug-detail visibility.
- Contact avatar matching (local-only) and initials/color fallback.

## 5. Requires server **API** changes (this phase)

- Add the optional fields above to the normal Message JSON
  (`GET /api/chats/{guid}/messages`, send response, `message:new/update/unsend`).
- Add `chatGuid` to messages and to all relevant WS events.
- Derive `isRetracted`/`isEdited` from the dates.
- Keep all existing fields; everything new is additive/optional (back-compat).

## 6. Requires chat.db **query** changes (this phase)

- Select the version-sensitive columns (`associated_message_type`,
  `associated_message_guid`, `thread_originator_guid`, `item_type`,
  `group_action_type`, `group_title`, `balloon_bundle_id`,
  `expressive_send_style_id`, `payload_data`, `error`, `date_retracted`,
  `date_edited`) **capability-gated** so older schemas still work.
- Persist them through the relay store (default api-store) via additive columns
  + sync writes; JOIN the existing `message_state` table for
  retracted/edited/error which the lookback update pass already maintains.

## 6b. What was implemented this phase

- **Server:** `MessageJSON` gained `chatGuid, associatedMessageType (int),
  associatedMessageGuid, threadOriginatorGuid, itemType, groupActionType,
  groupTitle, balloonBundleId, expressiveSendStyleId, payloadDataPresent, error,
  dateRetracted, dateEdited, isRetracted, isEdited` (all additive). chat.db sync
  queries select these capability-gated; relay store persists them (new columns
  + sync write) and JOINs `message_state` for retract/edit/error; all reads
  (`/messages`, send response, `message:new/update/unsend`, `send:match`) carry
  the enriched payload + `chatGuid`.
- **Client model/render:** tapback code→kind map (love/like/dislike/laugh/
  emphasize/question, add vs remove), reaction target-GUID parsing, reply
  detection via `threadOriginatorGuid`, effect-id→label map, retracted kind +
  label, **emoji-safe** control filter (non-ASCII = real content).
- **Client display:** `MessageDisplayPrefs` (hide unsupported / merge system /
  merge tapbacks / effect hints / delivery-label mode / debug-detail mode),
  persisted; `buildDisplayRows` applies them (never hides failed outgoing);
  thread renders reaction chips, reply previews, effect hints, unsent rows.
- **Avatars:** lazy per-id contact thumbnail (`photoThumbnail`) with in-memory
  cache + initials fallback (`HandleAvatar`); wired into chat list + thread
  header. flutter_contacts 2.2.1 fetches a single contact's thumbnail by id
  (`FlutterContacts.get(id, properties:{photoThumbnail})`) — no bulk photo load,
  so it scales; bulk thumbnails remain impractical, hence the lazy approach.
- **Inspector (Part K):** rendering recommendation + reaction/reply/effect/
  retracted flags + target GUID + "Copy client fixture" (MicaGo-client-shaped
  sanitized JSON for Flutter tests).

## 7. Still blocked / deferred

- Full effect **animations** (we render a text hint only — by design).
- `attributedBody` rich runs (mentions, inline styling) — we decode plain text;
  inline mention spans are not parsed.
- Interactive balloon **payloads** (Apple Pay, Digital Touch rendering) — we
  show a generic interactive hint only.
- Chat-list **unread / last-message preview / participants** — only surfaced if
  the server later exposes them; client keeps graceful fallback.
- Push / Firebase — explicitly out of scope for this phase.
