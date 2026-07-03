# Android stability, notifications, and chat-UI map

Reference for testing the Android client, the BlueBubbles notification gap
analysis, and the chat-UI file map for later polish. (C30)

> **C31 — notification reliability completion.** See
> [notifications-setup.md](../../docs/notifications-setup.md) for the user-facing setup/test
> guide. The C31 implementation notes are in [§6](#6-c31-notification-reliability).

## 1. Android stability audit

Status of the common failure modes, with where each is handled. Most were
hardened in earlier cycles (see `CHANGELOG.md`); this pass re-confirmed them.

| Area | Status | Where / notes |
| --- | --- | --- |
| Reconnect loop / backoff | OK | `RefreshCoordinator` (reconnect + fallback poll). Single owner; no competing timers. |
| Stuck "Reconnecting…" while connected | Fixed | `AppController.connectionHealthy` clears the sticky banner on the `connecting→connected` edge (`ConnectionNoticeHost`). |
| First-connect never resolves | Fixed | 10s watchdog → clear "can't reach server" dialog with Retry; cleared on success; background reconnects don't arm it. |
| Device registration | Fixed | Registers on **REST** candidate selection *and* WS connect, via a dedicated short-lived client (immune to `_rebuildApi()` close-race), retried 3×, logged both sides. Idempotent by stable device id. |
| Keep-alive foreground service | OK | `KeepAliveService` (Android, `dataSync` type), opt-in, default off, persisted (`micago.keepalive.v1`), restored on bootstrap. |
| Firebase optional path | OK | `PushService.start()` no-ops when `/api/fcm/client` reports unconfigured → app stays on WS + delta. |
| Notification permission | OK (FCM path) | `FirebaseMessaging.requestPermission()` requests POST_NOTIFICATIONS on first run when Firebase is configured. **Residual:** with keep-alive on but permission denied on Android 13+, the persistent notification may be hidden though the service still runs. |
| Background/foreground lifecycle | OK | `home_screen.didChangeAppLifecycleState` → `onResume()` → refresh-coordinator resume + push start. |
| Resume delta catch-up | OK | `onResume` → `catchUp`; WS connect → `_handleWebSocketReconnect` → `catchUp`. |
| Notification tap routing | OK | `onMessageOpenedApp` / `getInitialMessage` / local-notif payload → `requestOpenChat(chatGuid)` → `pendingOpenChat` → Chats tab opens the thread. |
| Duplicate foreground notifications | OK | `pushShouldCatchUp`: when the socket is connected the FCM message is ignored (no duplicate); local notifications are only shown from the background isolate. |

No new always-on logging was added; registration/connection already log to the
in-app connection log (Debug → realtime events) and the backend stdout. The only
additions this cycle are the (debug-guarded) `debugPrint`s already present.

## 2. BlueBubbles notification gap table

BlueBubbles builds notifications **natively in Kotlin**
(`CreateIncomingMessageNotification.kt`); micaGO builds them in Dart via
`flutter_local_notifications`. Behavior compared:

| Behavior | BlueBubbles | micaGO (now) | Decision |
| --- | --- | --- | --- |
| When to send push | Server pushes on new message; client treats it as a wake | Same (server FCM provider; wake-only) | — |
| Foreground vs background | FG handled by socket; BG shows a notification | Same (FG = socket dedup, BG = local notification) | — |
| Deduplication | Skip if socket already delivered | Same (`pushShouldCatchUp`) | — |
| Grouped notifications | Group key + group summary + `GROUP_ALERT_CHILDREN` | **Group key added (C30)** | **Ported (group key).** Summary notification deferred (low value for a wake signal). |
| Notification title/body | Sender name + message preview | Cleaned title/body helpers (C30) | **Ported.** |
| Channel importance | High-importance channel | High-importance channel | — |
| Tap → open chat | Opens the conversation | Same | — |
| Direct / inline reply | `RemoteInput` "Reply" action → native send | **Added (C30):** RemoteInput action → backend `sendText` via persisted profile (works from the background isolate) | **Ported (lightweight).** |
| Contact avatar in notification | `Person` + `contact_avatar` bitmap (MessagingStyle) | App icon only | **Defer.** Needs the contact photo plumbed into the (background) isolate; heavier and permission-dependent. |
| Mark read from notification | "Mark read" action → marks read on the Mac | Not supported | **Defer.** micaGO's read path is one-directional; there is no server "mark read" endpoint (would need IMCore mark-read). |
| Conversation bubbles | `BubbleMetadata` | Not supported | **Defer.** Niche; heavier. |
| Foreground-service keep-alive | Opt-in `keepAlive` socket service | Opt-in `KeepAliveService` | Parity (already present). |

## 3. Notification improvements shipped (C30)

In `lib/core/network/push_service.dart` + `push_logic.dart`, no new dependencies:

- **Grouping:** message notifications share `groupKey: micago.messages` so the OS
  bundles them.
- **Title/body formatting:** pure `notificationTitle` / `notificationBody` helpers
  (tested) — sender name as title, preview as body, sensible fallbacks.
- **Direct reply:** an Android `RemoteInput` "Reply" action. The reply is sent by
  `sendNotificationReply` — it loads the persisted `ConnectionProfile` from
  secure storage and POSTs to `/api/chats/{guid}/send` (reusing the existing
  bearer token + send API), so it works even from the background isolate with no
  live `AppController`. Registered for both the foreground and background isolates.
- **Tap-opens-chat** and **dedup** unchanged (already correct).
- Firebase and keep-alive remain optional and off by default.

Deferred (documented above): contact avatar, mark-read, bubbles, group summary.

## 4. Chat UI code map (for later polish — not redesigned here)

All under `MicaGoFlutterClient/lib/`:

| UI element | File · widget |
| --- | --- |
| Chat list (screen) | `features/chats/chat_list_screen.dart` · `ChatListScreen` |
| Chat list (data/state) | `features/chats/chat_list_controller.dart`; rows use `features/chats/avatar.dart`, `route_label.dart` |
| Chats pane (large-screen layout) | `features/chats/chats_pane.dart` |
| Thread screen | `features/chats/message_thread_screen.dart` · `MessageThreadScreen` |
| Thread state / presentation | `features/chats/thread_controller.dart`, `store/thread_presentation.dart`, `store/message_collection.dart` |
| Message bubble | `message_thread_screen.dart` · `_MessageBubble` / `_MessageBubbleState` (also `_SystemRow`, `_Footer`, `_DateSeparator`) |
| Reaction chips / reply preview | `message_thread_screen.dart` · `_ReactionChips`, `_ReplyPreviewBlock` |
| Message classification / render rules | `features/chats/message_render.dart`, `message_display.dart` |
| Image / media rendering (inline) | `features/chats/attachment_views.dart` · `AttachmentView`, `_ImageAttachment`, `_VideoAttachment`, `_AudioAttachment`, `_FileAttachment`, `_PreviewUnavailableAttachment`, `_StickerAttachment`, `UrlPreviewCard` |
| Full-screen media viewer | `features/chats/media_viewer.dart` · `MediaGalleryViewer`, `_ZoomableImage`, `FullscreenVideo` |
| Attachment picker / preview strip | `features/chats/attachment_panel.dart` · `AttachmentPanel`, `_MediaTile`, `StagedAttachmentStrip` |
| Input bar / composer | `message_thread_screen.dart` · `_Composer` / `_ComposerState` |
| Emoji panel | `message_thread_screen.dart` · `EmojiPanel`; glyph helper `features/chats/emoji_text.dart` |
| Long-press action menu | `message_thread_screen.dart` · `showMessageActionMenu` (Copy / Message Info / Edit / Unsend / Delete) |
| Message info / debug sheet | `features/chats/message_debug_sheet.dart` |
| Per-chat send route label | `features/chats/route_label.dart` · `routeLabel` |
| Server route selector (LAN/Public) | `features/settings/settings_screen.dart` · `_RouteSwitcher` |
| Notification-tap navigation | `core/app_controller.dart` `requestOpenChat`/`pendingOpenChat` → `features/home/home_screen.dart` `_onOpenChatRequested` → `features/chats/chat_list_screen.dart` (opens the thread) |

**Safe places for later UI polish** (self-contained widgets, low blast radius):
`_MessageBubble`, `attachment_views.dart`, `media_viewer.dart`, `EmojiPanel`,
`_Composer`, `avatar.dart`, and `chat_list_screen.dart` rows. Cross-cutting
logic (`message_render.dart`, `thread_presentation.dart`) is well-tested — change
with care and re-run the message-render/semantics tests.

## 5. Validation

- `flutter analyze` — clean.
- `flutter test` — passes (incl. new C30 notification-formatting/reply tests).
- `flutter build apk --debug` — builds.
- Go: backend send/notification APIs were **not** changed this cycle (the client
  reuses the existing `/api/chats/{guid}/send`), so no Go changes; `go test` is
  unaffected.

### Manual test checklist

- [ ] No Firebase configured → app works on WS + delta; no crashes.
- [ ] Firebase configured → token registers; Push Devices shows the device.
- [ ] Keep-alive off → no persistent notification.
- [ ] Keep-alive on → persistent notification; survives app restart.
- [ ] Foreground message → no duplicate notification (socket delivered it).
- [ ] Background message → grouped notification with a Reply action.
- [ ] Killed-app push → best-effort notification (needs runtime options/keep-alive).
- [ ] Notification tap → opens the correct chat.
- [ ] Direct reply from the notification → message sends to that chat.
- [ ] Paired Devices shows active WebSocket connections; Push Devices shows
  push/background status.

## 6. C31 notification reliability

Completes the notification path: real contact names, a keep-alive local-
notification path that needs no Firebase, cross-path dedup, and diagnostics.

### What changed

**Server (`internal/notify`)**
- The FCM data payload now carries `handle` (the raw sender address) alongside
  `chatGuid`/`sourceRowId`/`title`/`body` (`payload.go`, `fcm.go`). Android
  delivery is already `priority: high`.
- `buildNotification` (`dispatcher.go`) uses the mature **"title = who, body =
  what"** layout: the title is the sender (chat display name, else handle), the
  body is the text only in `sender_and_text` mode; `none` stays a generic wake.
  Never a GUID or empty title.

**Android client**
- `core/network/notification_display.dart` (new) — the single definition of the
  message channel (high importance), group key, inline-reply action, and the
  `notificationIdForMessage` dedup id. Both the FCM background isolate and the
  keep-alive path render through `showMessageNotification`, so an FCM push and a
  keep-alive notification for the same message **collapse into one** (same id).
- `push_logic.dart` — pure, tested `messageNotificationTitle` (contact name →
  server sender → handle → generic; never GUID/empty) and `localNotificationBody`
  (honors the preview mode).
- `push_service.dart` — local notifications now initialize **independently of
  Firebase** (`_ensureLocalNotifications`), so keep-alive notifications work with
  no FCM. Adds Android 13+ permission query/request. FCM display goes through the
  shared presenter; the background isolate uses the server name + handle.
- `app_controller.dart` — when the app is **backgrounded** and **keep-alive** is
  on, an incoming realtime `message:new` becomes a local notification
  (`_maybeNotifyBackgroundMessage`) with on-device contact-name resolution
  (`contactNameResolver`), the same formatting, tap routing and reply action.
  Foreground messages no-op (the UI shows them). Tracks `isForeground` from the
  shell lifecycle. Adds diagnostics: notification permission, last notification
  source, last direct-reply result.
- `settings_screen.dart` — Android 13+ "Notifications are turned off" warning +
  "Turn on", clearer Firebase-vs-keep-alive copy, and a **Notification
  diagnostics** expander (copyable, token/text-free).

### Dedup matrix (verified by design)

| Case | Result |
| --- | --- |
| Foreground + WS | No system notification (UI shows it; `isForeground` guard). |
| Background, FCM only | One FCM notification. |
| Background, keep-alive only | One local notification (no Firebase). |
| Background, FCM **and** keep-alive | One notification (shared id replaces). |
| Missed push | Delta catch-up restores messages silently — no notification spam. |

### Deferred (unchanged from C30, documented)

Contact avatar, mark-as-read from the notification, conversation bubbles, and a
group summary notification. Reasons in [§2](#2-bluebubbles-notification-gap-table).

## 7. C32 release-candidate chat UX

Three user-visible fixes (app renamed **micaGO**). Lightweight; no chat redesign.

### Native-style notifications (Android MessagingStyle)

- `showMessageNotification` (`notification_display.dart`) now builds an Android
  **MessagingStyle** notification: `Person` (sender name + avatar), per-message
  lines, conversation title. Replaces the old single-line style.
- **Grouped/stacked by chat:** the notification id is keyed by **chat**
  (`notificationIdForChat`), so new messages from the same chat update one
  conversation notification instead of stacking separate ones.
- A small persisted buffer (`notification_store.dart`, secure storage so both the
  FCM background isolate and the keep-alive main isolate share it) holds the last
  ~6 previews per chat for the stacked view, **dedups by message guid** (FCM +
  keep-alive of the same message → one line), and is **cleared when the chat is
  opened** (`cancelChatNotification`, wired through `requestOpenChat`).
- **Contact name + avatar:** keep-alive path resolves both on-device (avatar via
  a temp bitmap file → `BitmapFilePathAndroidIcon`); the FCM isolate uses the
  server name + a default monogram. Never a GUID/empty title.
- **Reply action removed** this pass (deferred — was C30/C31; not shown now).
- Foreground dedup, Firebase-optional and keep-alive-optional all unchanged.

### Third-party stickers

- `AttachmentView` routes anything `isStickerLike` (`isSticker` /
  `displayKind`/`attachmentKind == 'sticker'`) to a new `_StickerAttachment`
  **first**, so stickers never fall through to a file/“TIFF” card.
- It tries to render the image; on fetch/decode failure (common for third-party
  packs in formats the server can't preview) it shows a clean **`_StickerPlaceholder`**
  ("Sticker" chip) instead of a broken/empty card. Sending stickers not in scope.
- BlueBubbles parity: stickers render as transparent media, tap toggles between
  full and faint opacity, and long-press opens the media viewer.

### URL previews

- Plain text URLs remain tappable, and the first URL in a message now gets a
  BlueBubbles-style `UrlPreviewCard`. The preview renders as its own block above
  the original linked text bubble, without an extra border, so the URL remains
  visible and tappable in the normal message bubble.
- Rich-link attachments with no MIME type (`mimeType == null`) are treated as
  link previews and reuse the same card. Metadata is fetched client-side and
  cached in memory; the server does not fetch arbitrary URLs.
- Current source audit note: BlueBubbles separates `realAttachments`
  (`mimeType != null`) from URL `previewAttachments` (`mimeType == null`), which
  explains why Apple URLBalloon payload records should not appear as ordinary
  blank file cards. micaGO mirrors that boundary by not promoting untyped opaque
  rows (for example UUID-only URLBalloon resources) to ordinary file attachments;
  typed files/media and stickers still render normally.

### Mature media viewers (`media_viewer.dart`)

- **Images:** animated **double-tap-to-zoom** (toward the tap point) on top of the
  existing pinch-zoom + swipe-between gallery.
- **Video:** center **play / pause / replay** button, **position / duration**
  labels around a themed scrubber, **tap to show/hide** controls with auto-hide
  while playing, and replay when finished (no more silent infinite loop).
