# MicaGoServer v0.32.0 Chat Media Compatibility

## Problems

- Sticker attachments can be stored as HEIC/HEIF or third-party sticker
  payloads. The Flutter Android client cannot reliably decode those raw files,
  so it may fall back to a plain "Sticker" placeholder.
- Apple associated sticker rows (`associated_message_type=1000`) are not normal
  messages. BlueBubbles overlays them on the target bubble.
- MicaGo-recorded voice messages are sent as `voice_*.m4a`; they should display
  as voice notes, not generic audio.
- Native Messages voice notes arrive as `Audio Message.caf`, which many Android
  media stacks cannot decode directly.
- The Messages "kept an audio message" row (`item_type=5` with a subject) is
  sync noise beside the real voice attachment.
- Voice-message undo-send can lag until the next sync pass, making it appear as
  though retract failed.

## BlueBubbles Reference

BlueBubbles treats stickers as visual media, downloads/caches the attachment
bytes, validates that the bytes decode as an image, and only falls back to an
unsupported placeholder when no renderable image can be produced.

BlueBubbles also:

- renders associated stickers over their target message;
- hides `itemType == 5 && subject != null` kept-audio rows;
- sends recorded audio attachments with an `isAudioMessage` form flag;
- sends edit/unsend with a `partIndex` and updates the visible message after a
  successful response.

## micaGO Behavior

- Sticker rows keep `attachmentKind=sticker` and `displayKind=sticker`.
- Sticker rows expose `/api/attachments/{guid}/preview`.
- The preview endpoint converts the local attachment to PNG with `sips`.
- The client first tries the PNG preview and falls back to the raw attachment
  bytes if conversion fails.
- Sticker-only messages render with a transparent bubble background.
- Associated sticker rows are consumed by the presentation layer and rendered as
  a transparent sticker strip over the target message.
- `voice_*.m4a` attachments are classified as `displayKind=voice`, while normal
  `.m4a` files remain ordinary audio.
- Flutter voice sends include `isAudioMessage=true`; the Go backend converts
  those uploads to `Audio Message.caf` before passing them to Messages, matching
  the native attachment container more closely.
- Audio playback uses `/api/attachments/{guid}/playable`; CAF attachments are
  transcoded to an AAC `.m4a` cache with `afconvert` so Android clients can play
  Mac-originated voice notes.
- Kept-audio system rows are hidden in the thread display.
- After a successful undo-send request, the Flutter thread patches the target
  message locally as retracted, then lets the normal sync/WebSocket path confirm
  the server state.

This keeps Android rendering stable without changing the raw attachment download
endpoint or hiding unrenderable sticker rows.
