# Client refactor notes (Mategram-style + iMessage compatibility)

Internal design note. Not a user guide.

## Mategram UI patterns we adopt

- **Two-pane adaptive layout** (already in `ChatsPane`): phone = single pane;
  wide ≥720dp = chat list (left) + thread (right), selection preserved on resize.
- **Lean bottom nav**: only **Chats** + **Settings** on phone. Everything else
  (People/Contacts, Connection diagnostics, Appearance, Language, Debug, About)
  moves *into* Settings as grouped sections.
- **Search at the top of the chat list** (in-list, not a nav tab).
- **Message density / grouping**: date separators, sender name only in groups,
  compact incoming/outgoing alignment, avatars on incoming rows.
- **Media viewer**: full-screen, dim background, pinch-zoom, close button.

## BlueBubbles iMessage behaviors we adopt (conceptually)

- **Sender ownership**: `isFromMe` first; else the `handle` (resolved to a
  local contact name when possible); else a neutral "Unknown" — never null/raw.
- **Service/group events** are derived from `itemType` + `groupActionType` +
  `groupTitle` ("X named the conversation…", "added/removed…", "left…"). These
  render as **centered subtle system rows**, not chat bubbles.
- **Tapbacks/reactions** are identified by `associatedMessageType` +
  `associatedMessageGuid` — they are *not* normal messages.
- **Delivery**: `delivered = dateDelivered != null`, `read = dateRead != null`,
  `error > 0 = failed`. Status is computed once, shown compactly, outgoing-only.
- **Unsupported items** render as a subtle placeholder, never broken text.

## What we will NOT copy

- ObjectBox/local DB layer (we are stateless-over-REST + WS).
- BlueBubbles' bubble skin / iMessage visual clone, effects, tapback overlay UI.
- Mategram's TDLib/Telegram data model, Kotlin/Compose code.
- Private-API send paths (reactions/edits/typing) — server doesn't allow them.

## Root cause of the observed "ugly messages"

| Symptom | Root cause | Fix |
| --- | --- | --- |
| **"+!" / "+$" text** | Server **attributedBody** decoder leaked the typedstream length-prefix byte (`+` + length char). Fixed server-side in **v0.11.5** (`internal/store/text.go`). If still seen, the running server binary predates that fix. | Client adds a **defensive control-payload filter** (`isControlLikeText`) so such artifacts render as "Unsupported item" instead of raw text. Real fix = run the v0.11.5+ server. |
| **Ownerless / no sender** | Incoming rows whose `handle` is null (system/group/some outgoing rows), or sender never resolved in the widget. | Centralized `resolveSenderLabel()`: isFromMe→"You", else contact-name(handle)→handle.id→"Unknown". |
| **"Unsupported" / weird formats** | Messages with no text + no attachments (tapbacks, service events, empty metadata rows) rendered through the text path. | `MessageRenderableKind` classification → unknown/service rows render as subtle system lines, never broken bubbles. |
| **Bad delivered/failed/sent** | Status logic scattered in widgets, mixed incoming/outgoing. | Single `MessageDeliveryState` computed once; outgoing-only display. |

## Server API gaps blocking better compatibility (Part K)

The server `Message` exposes only: `guid, text, subject, service, dateCreated,
dateRead, dateDelivered, isFromMe, isRead, isDelivered, handle{id,service},
cacheHasAttachments, attachments[]`. It does **not** expose:

- `associatedMessageType` / `associatedMessageGuid` → **tapbacks/reactions can't
  be identified** by the client (they arrive as odd text/empty rows).
- `itemType` / `groupActionType` / `groupTitle` → **group/service events can't be
  rendered** ("named the conversation", join/leave, etc.).
- `error` on the message → incoming failed state unknown (we only know failure
  for messages *we* sent this session).
- `chatGuid` on `message:new`/`update`/`unsend` → can't target the open thread
  (debounced reload fallback).
- chat-list **last message / timestamp / unread / participants** → no previews,
  ordering, or badges.
- **media-send route** → attachment sending stays disabled.

Best safe fallbacks are implemented; the above are the server changes that would
unlock full compatibility before/with push.

## C3R deep audit (source actually read)

### BlueBubbles files inspected
- `lib/database/io/message.dart` — the `Message` model + getters.
- `lib/helpers/types/helpers/string_helpers.dart` — `sanitizeString`.

**Fields BlueBubbles relies on to classify a message** (from `message.dart`):
`text`, `subject` → `fullText = sanitizeString([subject,text].join)`;
`balloonBundleId` → `isInteractive` (Apple Pay / Digital Touch / Handwriting /
URL balloons); `associatedMessageGuid` + `associatedMessageType` +
`associatedMessagePart` → **tapbacks/reactions**; `itemType` + `groupActionType`
+ `groupTitle` → **group/service events** (`isGroupEvent`, `groupEventText`);
`payloadData` → rich link/interactive payload; `expressiveSendStyleId` → effects;
`error` (int) → failed; `dateDelivered`/`dateRead`/`isDelivered` → status;
`handle` → sender; `attachments` + `hasAttachments`; `bigEmoji`.
`sanitizeString` = strip `U+FFFC` only.

### Fields micaGO server exposes today
`guid, text, subject, service, dateCreated, dateRead, dateDelivered, isFromMe,
isRead, isDelivered, handle{id,service}, cacheHasAttachments, attachments[]`
(attachment: `guid, filename, mimeType, transferName, totalBytes, downloadUrl,
uti, isSticker, attachmentKind, isVoiceMessage`).

### Missing fields ⇒ why messages look "Unsupported"
BlueBubbles distinguishes reactions / interactive balloons / group events /
effects using `associatedMessageType`, `balloonBundleId`, `itemType`,
`groupActionType`, `payloadData`, `expressiveSendStyleId`. **micaGO exposes none
of these.** So when iMessage stores one of those rows, micaGO returns a message
with empty/odd `text` and no attachments → our client can only see "no text + no
attachment" and must show a generic placeholder. The **debug inspector (Part A)**
captures the raw payload so we can confirm which case each is and prioritise the
server fields to add (Part K).

### Mategram files inspected (Jetpack Compose)
- `presentation/chats/screen/ChatsListScreen.kt`, `ChatListContent.kt`,
  `ChatAvatar.kt` — list density, avatar-left + two-line row, folder tabs with
  unread pills, a top avatar that opens profile/settings.
- `presentation/messages/screen/` — thread list + input bar.
- `presentation/mediaviewer/screen/MediaViewerScreen.kt` — full-screen pager
  media viewer with zoom.
- `presentation/root/` — adaptive navigation.

**UI patterns ported:** avatar-left two-line chat rows; search at top of the
list; a profile/settings entry from the list app bar (not a noisy bottom nav);
list/detail split on wide screens; full-screen media viewer with zoom + dim
background; compact message density with date separators and grouped spacing.
**Not copied:** Compose code, TDLib model, folders/multi-account.

## Flutter code areas refactored

- `features/chats/message_render.dart`: pure classification — renderable kind,
  delivery state, sender label, control-text filter; **C3R additions**:
  `UnsupportedReason` + `MessageClassification`/`classifyMessage` (why a row is
  unsupported), `redactJson`/`messageDebugMap`/`messageDebugJson` (token- and
  URL-credential-redacted debug view), `ThreadDiagnostics` +
  `computeThreadDiagnostics`/`threadDiagnosticsReport`.
- `models/message_model.dart`: optional iMessage fields (associated*, itemType,
  groupActionType, groupTitle, error) + a debug-only `raw` map (original server
  JSON, never rendered, redacted before display).
- `message_debug_sheet.dart` (new): tap an unsupported/system row or long-press
  a bubble → Message Debug inspector (classification chip, flat fields, redacted
  raw payload, "Copy debug JSON"). **Token/URL credentials are never included.**
- `diagnostics_store.dart` (new): `lastThreadDiagnostics` notifier the open
  thread updates; read by Settings → Message Compatibility Diagnostics.
- `settings/diagnostics_page.dart` (new): counts by kind, unsupported reason
  breakdown, redacted last-unsupported preview, "Copy debug report".
- `media_viewer.dart` (new): full-screen gallery — dim background, pinch-zoom
  (`InteractiveViewer`), swipe between a message's images, loading/error+retry.
  Bytes come from `ApiClient.getAttachmentBytes` (token in header, not URL/log).
- `message_thread_screen.dart`: classification-driven rows; subtle tappable
  system/unknown rows (no inline raw dumps); grouped bubble spacing + tail
  radius; delivery status shown only on the latest outgoing message (failed
  always actionable); image bubbles open the gallery.
- `chat_list_screen.dart`: in-list `SearchBar` filtering title/contact/identifier
  /service/preview; graceful subtitle + timestamp-only-if-real fallbacks kept.
- Navigation: bottom nav → Chats + Settings; Settings holds Connection /
  Appearance / Contacts / Message Diagnostics / Debug / About.

### Tests added (C3R)
`test/message_diagnostics_test.dart`: classification reasons (control/no-content
/missing-fields/tapback), debug JSON redaction (sensitive keys + `Bearer …` /
`token=…` patterns), attachment download token never serialised, text-preview
clipping, attachment kind detection, thread-diagnostics counts + reasons, report
redaction. `flutter analyze` clean; `flutter test` 87 passing; `flutter build
apk --debug` succeeds.
