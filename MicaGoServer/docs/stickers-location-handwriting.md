# Stickers, location, handwriting & voice (C37)

How micaGO classifies and renders the iMessage message types that used to show as
broken/empty cards. Detection follows Apple's interop formats (the same signals
BlueBubbles reads); the logic is reimplemented in our server + Flutter client.

## Stickers (fixed display + transparent bubble)

- **Server** (`internal/store/attachmentkind.go`): an attachment classifies as a
  sticker from the chat.db `is_sticker` flag **or** its UTI (`com.apple.sticker`,
  `*.sticker`) — the UTI fallback catches third-party sticker packs whose flag
  isn't set. (Hidden link-preview parts are still excluded via `hide_attachment`,
  C34.)
- **Client**: `AttachmentView` routes anything `isStickerLike`
  (`isSticker`/`displayKind`/`attachmentKind == sticker`) to `_StickerAttachment`,
  which renders the image (tap to fade, long-press to enlarge) and falls back to a
  clean "Sticker" chip when the bytes can't be fetched/decoded.
- **Transparent bubble**: a sticker-only message (`stickerOnly` in
  `_MessageBubble`) strips the chat bubble — the sticker floats with no colored
  background, like the Messages app.

## Location

- **Server**: a shared-location row (the Maps "Send My Current Location" payload)
  is a small vlocation file. Classified as `AttachmentKindLocation` /
  `DisplayKindLocation` by MIME (`text/x-vlocation`), UTI (`public.vlocation`), or
  extension (`.loc.vcf` / `.vlocation`). It carries an Apple Maps URL in its body.
- **Client**: `_LocationAttachment` fetches the small payload, extracts the Maps
  URL, and shows a clean **Location** card with **Open in Maps** (`url_launcher`).
  Never a raw/broken file card; degrades to a plain Location chip if no URL.

## Handwriting & Digital Touch

- These are interactive balloons whose **attachment is already the rendered
  media** — a PNG for handwriting (`com.apple.Handwriting.HandwritingProvider`), a
  MOV for Digital Touch (`com.apple.DigitalTouchBalloonProvider`). So they render
  through the normal image/video path.
- **Client** (`MessageModel.isHandwritten`/`isDigitalTouch`/`isEmbeddedMedia`):
  the bubble is made **transparent** (`embeddedMedia` → `stripBubble`), so the
  handwriting/animation shows with no chat bubble behind it. Full interactive
  playback/authoring is out of scope.

## Voice messages

- **Receiving** already works: a voice memo (CAF UTI/MIME, `IsVoiceMessage`) →
  `DisplayKindVoice` → the client's `_AudioAttachment` plays it.
- **Sending (shipped):**
  - Dependency `record: ^5.2.1`; Android `RECORD_AUDIO` permission (requested at
    runtime on first record).
  - `voice_recorder.dart` — a small `VoiceRecorder` wrapping `AudioRecorder`:
    `start()` (requests mic permission, records AAC/m4a to a temp file),
    `stop()` → `(bytes, filename)`, `cancel()`. Failures return null (no crash);
    the caller shows a banner.
  - The composer's voice button now **starts recording**; while recording a
    `_VoiceRecordingBar` (red pulse + `mm:ss` timer + Cancel / Send) replaces the
    input row. Send → `stop()` → `sendAttachments([StagedAttachment(bytes,
    voice_*.m4a)])` — the **existing, tested send-attachment path**. Gated by the
    chat's `canSendAttachments`.
  - Server: `POST /api/chats/{guid}/send-attachment` already sends arbitrary files
    via AppleScript, so the m4a sends as an attachment — **no server change**. A
    true expiring iMessage "audio message" (audio-message flag via IMCore) is a
    further step, not done.
  - **Needs device verification:** mic capture + actual delivery can't be
    exercised here; the pieces compile (analyze clean, APK builds) and degrade
    gracefully, but confirm on a real device.

## Validation

- Go: `go vet ./...` clean; classification tests in
  `internal/store/attachmentkind_test.go` (location + sticker-UTI). (`go test
  ./...` passes except the pre-existing TCC-gated `TestSendAttachmentSMSGate`.)
- Flutter: `flutter analyze` clean; widget tests for sticker render/placeholder
  and the location card (`test/chat_media_widgets_test.dart`); `flutter build apk
  --debug` builds.
- Backend version bumped to **v0.32.0**. Requires rebuilding the bundled backend
  for the server classification to take effect.
