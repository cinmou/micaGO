# AGENTS.md — working guide

Live notes for Codex when working in this repo. Keep it short; update it as part of any pass.

## What MicaGo is

Four components:

- **Go relay server** — `MicaGoServer/micago-server`. Reads the Mac's Messages DB, exposes a local control + chat API, syncs into `relay.db`, serves chats/messages/delta + WebSocket. Tests: `go test ./...`, `go vet ./...`.
- **macOS Companion** (SwiftUI) — `MicaGoServer/micago-mac-companion`. Menu-bar + dashboard that launches/monitors the server, manages pairing/URLs, sync rules, devices, notifications. Build: `xcodebuild`.
- **Flutter Android client** — `MicaGoFlutterClient`. Pairs over LAN/public URL, syncs, sends, optional FCM push. Checks: `flutter analyze`, `flutter test`, `flutter build apk --debug`.
- **Windows client** — `MicaGoWindowsClient` (WinUI 3/.NET). Uses cache-first SQLite, REST delta + authenticated WebSocket hints, persistent media cache, optimistic sends, native notifications/tray, and optional local vCard contact matching. Build: `dotnet build MicaGoWindowsClient/micaGO.Windows.sln -c Debug`; contract checks: run `tests/micaGO.Core.ContractTests`.

## Important rules

- **Never commit unless explicitly asked.** Branch first if on `main`.
- **Never log, commit, or expose** bearer tokens, push tokens, or service-account paths. The Companion redacts tokens in captured server stdout (`BackendController.redact`).
- Keep it **lightweight** — no new dependencies without a clear need.
- **Firebase, keep-alive, and IMCore message actions are all optional and off by default.** Don't word docs/UI as if they're required or guaranteed.
- Keep final logs clean (debug-guarded only).
- Companion menu-bar icon must use **template rendering** (no hard-coded colors) so it adapts to light/dark menu bars.
- **Before debugging sync, check the running backend binary's version against source** — a stale binary is a common false lead. Rebuild via `scripts/build-backend.sh`.

## Known UI/state notes

- **Windows UI:** low-tint `MicaKind.Base` is intentionally visible through the native title bar and sidebar; the contact bar is a low-tint Acrylic overlay above the message canvas so the thread can subtly show through, while secondary-page headers use the same Unigram-style material. Settings/details and the default message canvas share `LayerOnMicaBaseAltFillColorDefaultBrush`; a custom background replaces only the message-canvas layer. The right master-detail surface owns one `NavigationViewContentGrid*` border/corner so its sidebar/header transition stays native. Native caption buttons require `TitleBarHeightOption.Standard` plus transparent theme-aware button colors. Window sizing is Per-Monitor V2 and converts logical design dimensions with `XamlRoot.RasterizationScale`, then centers inside the display work area. Message direction/corner transitions use XAML visual states; do not reintroduce hard-coded light/dark colors in code-behind. Outgoing bubble geometry remains in XAML; `AppearanceService` only supplies system-accent/custom color and contrast-safe text. A `ListViewItemPresenter` must remain the root of every custom `ListViewItem` template; the chat list uses its native selection indicator because wrapping the presenter to add a second indicator crashes WinUI template activation in Release.
- **Windows chat refresh:** `ChatSummary` is a stable `INotifyPropertyChanged` row. `ListKey` is the UI identity (a deterministic route-set key for merged contacts), while `PrimaryRouteId` can change to the newest send route without replacing the row. `ChatListCollection.Apply` is the only visible-chat reconciler and emits only minimal Move/Insert/Remove notifications; do not restore `ReplaceChats`/`SyncChat`/`SyncChats`, whole-row replacement, Reset, or Replace. Realtime batches rebuild the selected message presentation only when that thread changed, ignore older events for chat preview/unread advancement, and deduplicate repeated WebSocket/delta message ids. `MessageSemantics.ReconcilePresentation` is the only local→server handoff: it preserves both `PresentationKey` and the optimistic `DateCreated`, so confirmation cannot reorder the row. Keep local mutations (`ApplyMessages`: append, Sending→Sent/Failed, exact `send:match`, deletion) separate from cache/REST snapshots (`MergeSnapshotMessages`); feeding an already-reconciled row back through snapshot merge resurrects the old pending row and creates duplicate presentation keys. `send:match` must use its exact `tempGuid`, while delta-only reconciliation consumes pending candidates one-to-one. HTTP 202 `send_confirmation_timeout` and completed attachment uploads are `Sent`/still pending, never failed or parsed as an incoming server message. Snapshot/live preservation is strictly limited to the selected chat's `RouteIds`: switching conversations clears the old raw scope, and neither confirmed nor pending rows from another route may survive `MergeSnapshot`. Clicking the already-open chat must not restart its cache+REST load. `SyncMessages` never calls `Messages.Move`, and preserves structurally equal media/reaction list references so immutable presentation passes do not replace every row; same-key `MessageBubble` updates must not reset visual state or rebuild unchanged media controls. Generic message-list content/container transitions, ordinary media fade-in, and delivery-footer Storyboards stay deleted because recycled WinUI containers made rapid updates flash or raise `E_INVALIDARG`; `ItemsStackPanel.KeepLastItemInView` owns append scrolling, so do not add per-send manual scroll passes. Conversation previews must use `MessageSemantics.PreviewText` so `obj`/object-replacement placeholders render as attachments.
- **Windows incremental rows:** realtime chat events update one canonical `ChatSummary` per chat and issue at most one visible `Move`; read-watermark advancement never runs the full chat diff. The message `ListView` binds stable `MessageRow` wrappers, so Sending→Sent/footer/grouping changes raise `Value` only and preserve the item/container identity. Full snapshot/filter reloads may still use keyed reconciliation; realtime events use the narrow `RealtimeChanged` surface instead of refreshing connection/loading state. New-message entrance is carried once by `MessageRow.MessageEntranceKind`, consumed only for fresh viewport-visible append rows, and rendered in `ShellPage` with Composition translation/opacity plus local-send scale. History, confirmation, footer/reaction changes and recycled containers never receive the entrance marker; keep generic `ItemContainerTransitions` empty.
- **Windows master-detail navigation:** `ShellPage` owns both panes. Settings swaps only the left chat list for a native settings `ListView` and navigates its section into the right `DetailFrame`; the settings list uses the default `ListViewItemPresenter` selection indicator and has no overlay indicator, stored offset, or manual Composition selection animation. Settings pages disable horizontal scrolling so their max-width card grids stay constrained to the detail viewport at every DPI. Conversation details also use that right frame while leaving the chat sidebar intact. Search uses the complete `AutoSuggestBox` suggestion/query flow and frames use native theme transitions. Message presentation keeps raw rows separate from derived separators/reactions, then applies Flutter-compatible 5-minute sender runs, 60-minute pause chips, group-tail corners, compact gaps, emoji/sticker stripping, and outgoing-only delivery footers.
- **Windows chat selection/reorder:** chat rows keep `ListViewItemPresenter` as the template root and use its native row-local selection indicator. Genuine single-row realtime moves use the Unigram-style visible-container Composition pass: 167-ms vertical translation plus target clipping, with no opacity/scale animation; initial snapshots, filters, insert/delete batches, offscreen changes, and disabled system animations snap directly. Do not add generic chat `ItemContainerTransitions` or a shared/flying selection indicator.
- **Windows navigation/resize:** secondary pages use the Unigram/WinUI hierarchy convention (`EntranceNavigationTransitionInfo` by default, `SlideNavigationTransitionInfo.FromRight` when entering); returning reveals the conversation with a native entrance transition. The shared 12-DIP `SidebarResizeGrip` is a lightweight custom WinUI control (WinAppSDK's `Thumb` is sealed), keeps the detail pane at least 380 DIP wide, and persists the sidebar-width ratio in SQLite. Do not restore adaptive width setters that overwrite the user's drag choice.
- **Windows Flutter-parity presentation pass:** `ThreadPresentation` in Core is the only message-row presentation builder; do not reintroduce ViewModel-side grouping. It distinguishes private/group behavior (group sender name on the run head, avatar on the run tail, no group delivery labels), merges Tapbacks/associated stickers/consecutive system rows, suppresses interactive updates and kept-audio notices, resolves replies/effect labels/edited markers, and owns localized time separators. The chat list refreshes relative timestamps each minute; the conversation header uses the same newest-activity timestamp instead of an SMS/iMessage service label. Settings is launched only from the native title-bar button left of `micaGO`; the sidebar settings button stays deleted. Contacts come only from `VcfContactImporter`; startup source-scoped cleanup removes legacy Google rows/settings/credentials. vCard imports are additive across files, update duplicate identities, persist embedded PHOTO data locally, and offer an explicit source-scoped clear-all action.
- **Windows link previews:** `LinkPreviewSemantics` mirrors Flutter URL extraction/normalization and Open Graph/Twitter/title fallback. `LinkPreviewCard` is the single renderer for one-URL message bodies and compact server link attachments; it caches metadata, resolves relative preview images, hides failed/empty previews, and never animates message rows. Do not restore the old icon-plus-`<title>` card in `MessageBubble`.
- **Windows reconciliation:** `MessageSemantics` owns visible-text normalization and pending/server matching. It strips U+FFFC/U+FFFD, uses 2-minute text and 5-minute attachment windows, matches attachment name/stem/size, and refuses ambiguous attachment fallback. Preserve server-authoritative confirmed media and stage all batch bubbles before uploading.
- **Windows optimistic rows/media:** `Message.PresentationKey` survives local→server confirmation. Attachment paths stay memory-only for retry; upload progress updates the same row. Bubble previews use a 64-item LRU and 900px decode bound; details uses smaller 360px previews.
- **Windows sync/page state:** `ShellViewModel` cancels the prior selection request, pages messages in 50-row chunks, stores `read.watermark.<chat>`, and persists unfinished attachment tasks in `pending_uploads`. Realtime events update chat preview/order/unread and suppress notifications for the open chat.
- **Windows local notifications:** the unpackaged self-contained Windows App SDK 2.2 build must carry `Microsoft.WindowsAppRuntime.Insights.Resource.dll`; without it `AppNotificationManager.IsSupported()` returns true but `Register()` fails with `0x8007007E`. `micaGO.App.csproj` extracts the architecture-matched DLL from the official Runtime framework MSIX after every app build. Load notification preferences before realtime starts, keep the initial history delta silent, and retain registration HRESULT/state for diagnosis.
- **Windows device presence:** `DevicePresenceService` mirrors Flutter: after each successful restore/pair it registers one stable random `windows-*` identity as `platform=windows`, `clientType=native`, `pushProvider=none`, then heartbeats every 30 seconds. The ID is stored in LocalAppData outside SQLite so cache clearing/settings backup cannot duplicate a device. Registration and heartbeat failures are best-effort and retry without blocking connection startup.
- **Windows thread scrolling/composer:** older 50-row pages load automatically when the native message `ScrollViewer` approaches the top; `ShellPage` preserves the first visible presentation key/pixel anchor and must not restore a manual “load earlier” button. Optimistic send/confirmation collection rebuilds keep the bottom anchored and suppress the top-pagination trigger so sending never jumps to history. The message list disables horizontal scrolling to prevent a transient gray scrollbar while realizing a new row; send-to-bottom realizes the final container, waits for layout, then corrects only a residual offset. The message canvas extends behind the bottom-aligned floating composer with bottom content padding. The outer Mica border owns all composer chrome; the native `TextBox` keeps selection/IME/text paste while its focused background, border and underline stay locally transparent. `PreviewKeyDown` makes Enter send reliably and Shift+Enter inserts a line break. Clipboard bitmap/storage-item paste reuses `SendAttachmentsAsync`, including virtual-file temp copies and bitmap-to-PNG transcoding. The composer follows Unigram's attachment | text | system emoji | contextual voice/send layout; its 48-DIP action slots use circular transparent 40-DIP native button surfaces, and the right action changes from voice to send only when visible text exists.
- **Windows contacts/routes:** users can select multiple `.vcf` contact cards locally; `FolkerKinzel.VCards` is the single parser, and RFC UID (or a persisted fallback id reused through existing identities) supplies stable `contact_id`. Embedded PHOTO data is content-hash cached under LocalAppData and used by chat/header/group avatars. Resolved 1:1 chats merge by `contact_id`, never display name; merge/send-route/mute/pin preferences use that stable key. Sends use the saved route, otherwise a sendable iMessage route, while the newest route still owns the preview. Clearing contacts deletes vCard/legacy CSV rows and cached avatar files only. Do not restore the hand-written vCard parser, title-keyed merging, Google OAuth/People sync, or CSV import UI.
- **Windows merged history:** `/api/messages/history` is the authoritative multi-route history endpoint and uses an opaque `(date_created, source_rowid)` keyset cursor. The Windows client must not restore parallel per-route REST fetches or offset paging. Cache and UI message identities are route-qualified (`chat_guid + guid/presentation key`); local SQLite uses `PRIMARY KEY(chat_guid,guid)`, and realtime dedup, hidden-message tombstones, reconciliation, notifications and read watermarks stay route-scoped.
- **Windows startup/package:** do not block or auto-navigate the pairing page while probing a saved route. A saved-profile auto-restore path caused a native WinUI `E_INVALIDARG` crash; startup now leaves JSON input interactive. The top-level `ConnectionWindow` and `MainWindow` are code-built native WinUI hosts because compiled Window XBF activation crashed in Release; do not restore those host XAML files. Pairing/network failures and post-pairing UI activation failures are reported separately. For test archives use the successful `dotnet build -c Release -p:Platform=x64` output; the RID-specific self-contained `dotnet publish -r win-x64` output currently crashes when activating compiled Page XBF files. The independent native tray window is opt-in only (`settings.tray == true`), never registered unconditionally; it registers `NOTIFYICON_VERSION_4`, closing hides a host window only while enabled, and tray Exit owns final disposal. Its native popup stays system-drawn and refreshes `PreferredAppMode.AllowDark` immediately before display so the menu follows the current Windows app theme; do not replace it with an owner-drawn menu. App/title/tray icons are runtime-local `Assets/micaGO.Windows.png` plus multi-size `Assets/micaGO.ico`; both native windows call `AppWindow.SetIcon` with the internal absolute ICO path, and `MainWindow` renders the internal PNG beside its title. `docs/assets/micaGO Windows.png` is only the design source copied at build-authoring time, never a runtime dependency.
- **Windows pairing startup crash:** `ConnectionWindow.xaml`/`ConnectionPage.xaml` produced an unpackaged Release XBF that crashed in `Microsoft.UI.Xaml.dll` (`0xc000027b`, COM `E_FAIL`) before managed exception handling. Both are intentionally code-built native WinUI surfaces now (`ConnectionWindow.cs`, `Views/ConnectionPage.cs`); do not restore compiled XAML for this startup path without an isolated publish-and-launch smoke test. `%LOCALAPPDATA%\micaGO\startup-crash.log` records managed startup failures.
- **Windows message presentation:** `BuildDisplayMessages` follows the Flutter grouping policy: 5-minute same-sender runs, tail only on the last bubble, day/60-minute separators, compact delivery boundaries, bubble-less 1–3 emoji, transparent sticker-only rows, merged reactions, reply previews, and centered service/retracted rows.
- **Windows Twemoji/package:** Appearance owns an opt-in, default-off `appearance.twemojiFlags` toggle with CC-BY 4.0 attribution and the non-affiliation disclaimer. When enabled, message bodies/replies replace only Unicode flag graphemes with 266 bundled Twemoji 17.0.3 SVGs; independently, the 163 fully-qualified Unicode Emoji 17 sequences always use bundled SVG fallback because Windows glyph coverage varies. Standalone skull and pre-17 ordinary emoji stay native. `FlagEmojiSemantics` is the shared grapheme recognizer; `FlagEmojiTextRenderer` uses only `Run`/`InlineUIContainer` mutation and catches asset failures to avoid toggle crashes. Do not add PNG emoji assets; `.gitignore` rejects them. Release archives must be produced by `MicaGoWindowsClient/scripts/package-release-x64.ps1`: it validates both SVG sets and excludes stale RID-publish output, non-x64 SQLite runtimes, unsupported MUI locales and PDBs.
- `serverDisplayState(process:reachable:)` (`BackendController.swift`) is the single source of truth for combined process+reachability state; both the menu-bar icon and the dashboard pill derive from it.
- Sync Control loads four endpoints (`sync/rules`, `sync/settings`, `chats`, `messages/recent`). A failure in any one is what users see as a page error.
- Contacts permission on macOS can only be prompted by the app once (`.notDetermined`); after that it's System-Settings-only. The UI must not offer a dead "Allow" button.

## Localization (zh-Hans + zh-Hant)

- **Flutter client:** `lib/core/l10n/app_localizations.dart` holds `en` / `zhHans`
  / `zhHant` tables (kept key-for-key parallel — verify with a key-diff before
  adding). `MicaLocalizations.of(context).t('key')` (falls back to `en`, then the
  raw key). Locale chosen in Settings (`settings.systemLanguage`/`english`/
  `zhHans`/`zhHant`); delegate maps `zh`+`Hant`→zhHant, `zh`→zhHans. The
  Notifications settings card + the chat "Sticker" label are localized
  (`notif.*`, `chat.sticker`); technical diagnostic key/value pairs stay English.
  Background-isolate notification strings (push_service) have no context, so they
  aren't localized.
- **Companion:** `Localization.swift` (`L10n.tr`) covers the sidebar + menu
  (en/zhHans/zhHant). Most dashboard body text is still hardcoded English (large
  follow-up).
- **Docs:** `README.md` + `README.zh-Hans.md` / `.zh-Hant.md` and `docs/index.md` +
  `index.zh-Hans.md` / `.zh-Hant.md` and `docs/getting-started.*` — each with a
  language switcher. C38 restyled the README + docs hub in a hero / language-switcher
  / key-links-bar / emoji-section / capability-table / "what it does vs does not do" /
  honest-limitations / closing-CTA style (centered `<div>` blocks render on GitHub).
  zh-Hant uses Taiwan terms (伺服器/訊息/預設/推播/貼圖/權杖/影片). The 4 individual
  guides (android-client-connection / remote-access-cloudflare / notifications-setup /
  manual-test-flow) are still English-only — the localized index marks them "(英文)".

## Video playable transcode fallback (C73)

- **"视频查看器坏了" root cause:** nearly every library video is iPhone-camera
  **HEVC (`hvc1`) in QuickTime** — server serving verified healthy (200/206
  Range, qlmanage posters fine), but Android devices without an HEVC decoder
  fail ExoPlayer init → the error card. Fix mirrors the CAF-audio design:
  `GET /api/attachments/{guid}/playable` now transcodes **videos** to H.264
  fast-start MP4 via the system `avconvert --preset Preset1920x1080`
  (`servePlayableVideo`, cached in temp, unique `.part` + atomic rename,
  3-min timeout; any failure falls back to the raw bytes — never worse).
  Verified live on a real HEVC .mov → `avc1` + moov-at-front. The client's
  `FullscreenVideo._init` retries once via `attachmentPlayableUrl` when the
  direct stream (cached file or raw) fails, so capable devices keep original
  quality and incapable ones self-heal. **Requires rebuilding the bundled
  backend.**

## Media loading skeleton — one-bubble placeholder → image (C69, client-only)

- Image, video, and sticker memory misses show one stable rounded
  `_MediaLoadingPlaceholder` with a kind-specific icon. `_MediaLoadSwap` keeps
  that placeholder behind a short media-only fade while `AnimatedSize` eases
  the same frame to the media's constrained intrinsic size. Never scale, slide,
  or circularly reveal the media: those transitions look like a second bubble
  entrance. Sync memory hits still render directly with no placeholder frame
  (C51).
- Optimistic attachment rows and their confirmed server rows share a
  presentation key recorded by `MessageCollection`. The list item, message
  `GlobalKey`, entrance tracking, and attachment subtree all use that key, so
  confirmation updates the existing bubble in place and preserves its loaded
  local bytes. Do not reintroduce GUID-keyed row replacement or a separate
  "suppress the second entrance" flag.
- Details media aggregation reads every message persisted for each route from
  SQLite, merges it with the live thread rows, and deduplicates messages and
  attachments by identity. Thread refresh/background sync uses
  `mergeServerPage`, so older pages fetched through pagination remain cached;
  the details preview and full gallery therefore cover the complete locally
  cached media history rather than only the current in-memory page.

## Participant send fallback + merged view beta + details l10n + UI polish (C68)

- **Sends to underscored-email handles failed** — Messages' AppleScript
  `chat id` lookup is unreliable for some 1:1 email handles even when the chat
  exists in chat.db. `AppleScriptSender.SendText/SendAttachment` now retry via
  `participant "<handle>" of (1st account whose service type = iMessage/SMS)`
  (`BuildSendToParticipantScript`, `DirectHandleFromChatGUID` — group `;+;`
  guids never take the fallback; original error is preserved if both fail).
  **Requires rebuilding the bundled backend.**
- **Merged view (beta, client):** per-contact toggle
  (`AppController.isMergedDisplayEnabled`, SecureStore
  `micago.merged_display.v1`) shown in the details Routes section when a
  contact has 2+ iMessage routes. `ThreadController` takes `mergedGuids`:
  load pulls the newest page of every route (paging older stays
  primary-route-only), WS/delta/unsend/reactions route on `threadGuids`,
  cache writes use the message's own chatGuid, sends stay on the active
  route. Toggling rebuilds the live controller (`_rebuildActiveController`).
- **Details sheet fully localized** (`details.*` keys ×3 locales; the media
  header reuses `chat.media`; subtitle 'iMessage 群聊' hardcoded-zh removed).
- **Text alignment:** composer TextField (both variants) gets explicit
  `height: 1.35` with a slightly raised content baseline; date-separator pills
  use `height: 1.0`, with the time-only label for today lowered independently
  from older date labels. The jump-to-bottom label uses `height: 1.0` +
  localized (`chat.backToBottom`) and the button is raised
  (`bottom: max(124, inset + 6)` from `max(94, inset − 32)`).

## U+FFFC reconciliation fix — photo sends showed two bubbles (C67, client-only)

- **Root cause:** chat.db stores attachment messages with the object-replacement
  character (U+FFFC) in the text column; the server's `ExtractMessageText` only
  TrimSpaces (FFFC isn't whitespace) so it reaches the client as `text`. The
  *render* layer always stripped it (`sanitizeMessageText`), but the
  *reconciliation* layer used raw `hasText` — so the confirmed server row of a
  photo send looked "captioned", both the identity branch (`!server.hasText`)
  and the attachment fallback rejected it, and the pending bubble + server row
  showed together. Reopening the thread "fixed" it because attachment pendings
  are memory-only.
- **Fix:** reconciliation now shares visible-text semantics —
  `_normaliseComparableText` strips U+FFFC/U+FFFD before trimming, and all
  has-text gates in `shouldReconcileLocalWithServer` / `matchingPendingTempId`
  go through `_hasComparableText`. A real caption (FFFC + words) still blocks
  bare-attachment matching. Tests: C67 group in
  `attachment_optimistic_send_test.dart`.

## Multi-image send corruption — server-authoritative media (C70, client-only)

- **"发多张图变成同一张发两遍":** the C66 "atomic handoff" seeded *local* bytes
  under *server* cache keys, gated by a `server.attachments.length == 1`
  short-circuit — with several sends in flight, the closest-by-time fallback
  could match the WRONG pending and permanently cache swapped photos on disk.
  All of that is gone: **confirmed media is server-authoritative** —
  `MediaCache.seed` and `_absorbConfirmedAttachmentSend` deleted; the media
  disk store moved to `media_cache/v2` with a one-time purge of the possibly
  corrupted v1 files (a just-sent photo now downloads back once, then caches).
- **Reconciliation authority is MessageCollection alone** (ingestion paths just
  `upsertServer` + `_sweepAttachmentSendBookkeeping`, which releases staged
  bytes/progress/pins when a pending vanished; failed pendings keep theirs for
  retry). The conversion fallback **refuses ambiguous (2+) candidates** again —
  closest-by-time guessing is what swapped bubbles.
- **Batch sends continue past a failure** (the failed file keeps its tap-to-
  retry bubble; the rest of the batch still sends — previously `break` meant
  "only the first image sent" whenever one item errored).
- **C71: all pending bubbles stage up front.** `sendAttachments` now runs two
  phases — enqueue every optimistic bubble (pin bytes, progress notifier,
  `dateCreated: baseMs + i` / `tempId: baseMicro + i` for stable unique order)
  in one setState, THEN upload sequentially. Previously each bubble was only
  added when its own upload started, so a multi-file batch showed just the
  first bubble until that upload finished. A pending deleted while queued is
  skipped (`pendingByTempId == null → continue`).

## Pending-attachment bubble conflicts (C66, client-only, v0.64.0)

- Pending bytes stay pinned in `MediaCache` until confirmation or deletion, so
  a local bubble never tries to fetch its `local-` guid from the server.
- ~~Closest-pending matching / atomic byte handoff~~ — superseded by C70
  (server-authoritative media, ambiguity-refusing fallback).
- Tests: C66 groups in `attachment_optimistic_send_test.dart`.

## Stable send confirmation + footer/timestamp l10n (C65/C69, client-only)

- **Send confirmation preserves the row**: `MessageCollection` maps a confirmed
  server GUID to the optimistic row's presentation key. The presentation model,
  list item, message `GlobalKey`, and entrance tracker all keep that key, so the
  footer can change to Sent/Delivered without recreating or reanimating the
  bubble. Pinned in `attachment_optimistic_send_test.dart` and
  `message_collection_test.dart`.
- **C72: footer transitions** — the `_Footer` mount in `_MessageBubble` is
  wrapped in `AnimatedSize` (220ms, aligned to the bubble's side) +
  `AnimatedSwitcher` (160ms side-aligned fade, keyed on
  showStatus/showTimestamp/deliveryState/isEdited), so a footer appearing on
  the newest row / leaving the previous one eases in and the rows above glide
  instead of jumping.
- **Footer l10n**: `_Footer`'s Sending…/Sent/Delivered/Read, the
  "Failed — tap to retry" line, and the Edited marker now use l10n keys
  (`chat.sending/sent/delivered/read/edited/failedTapRetry`). `editedMarker`
  stays pure-English (tests pin it); the UI translates at render.
- **Relative timestamp l10n**: `chatTimestampLabel`'s "now"/"5m" buckets were
  English-only → `_nowLabel`/`_minutesAgoLabel` (刚刚/剛剛, N 分钟前/分鐘前).
  Chinese needs the *script*, so callers pass the full language tag — the chat
  list's `_formatTime` switched from `languageCode` to `toLanguageTag()`.
  Tests in `chat_timestamp_test.dart` (zh-Hans/zh-Hant/zh-TW).

## Unified long-press menu + thread multi-select + forward fixes (C64, client-only, v0.63.0)

- **One long-press surface.** Attachment tiles no longer open the old bottom
  sheet in threads: `AttachmentView` takes `onLongPress(position, attachment)`,
  threaded into every tile (image/sticker/video/audio/file/preview-unavailable
  via `_tileLongPress`), and `_MessageBubble.onActions` carries the pressed
  attachment into `showMessageActionMenu`, which now includes Save/Share/Open
  items (dispatching to the public `runAttachmentAction`) plus a Select entry.
  Media bubbles also get a bubble-level long-press (previously only tiles
  responded). Standalone contexts (details grid, fullscreen viewers, ⋮ button)
  keep `showAttachmentActions`.
- **手感:** the menu no longer awaits a full HTTP round-trip —
  `getMessageActionCapabilities` is cached module-wide (2-min TTL, prefetched
  on thread open); a cold cache waits ≤300ms then opens with last-known caps
  (a test pins that Edit/Undo/Delete appear on first long-press). Haptics:
  mediumImpact on menu open, selectionClick on select toggles.
- **Multi-select** (`_enterSelectMode` via the menu's Select item):
  `_SelectableMessageRow` slides **incoming** bubbles right (34px × animated
  progress, same pattern as the timestamp reveal) with check circles on the
  left; outgoing stay put (right-aligned). Whole row is one tap target
  (AbsorbPointer suspends bubble gestures). The composer swaps for
  `_SelectionActionBar` (Forward (n) / Hide (n) / ✕). Batch hide =
  `ThreadController.hideMessages` (one reload); batch forward = one target
  pick, then each message sequentially.
- **Forward fixes** (`_forwardMessages`): `send_confirmation_timeout` no longer
  reported as failure (the message did send), a catch-up runs afterwards so
  forwarded rows appear promptly, and pending `local-` attachments are skipped.

## Persistent media cache + optimistic attachment bubbles + entrance animation (C63, client-only)

- **Media now persists on disk — permanently.** `MediaCache`
  (`core/storage/media_cache.dart`) adds a disk layer (app-support/media_cache,
  atomic `.part` writes, **no eviction** — removed only with app data) under the
  in-memory `LruByteCache` (now a private `_memoryCache` there; the old public
  `imageByteCache` in media_viewer is gone — call sites use
  `MediaCache.instance.memoryHit/load/seed`). Reads go memory → disk → network
  with in-flight dedup; every fetch writes through. **`init()` resolves the
  directory once in `AppController.bootstrap`** — before/without it the cache
  degrades to memory+network (this keeps widget tests off the path_provider
  platform channel; a per-load `getApplicationSupportDirectory()` hung them).
  All preview/full fetch sites route through it (image/sticker/video tiles,
  gallery viewer, details grid, save/share/forward); `FullscreenVideo` plays
  from the cached file when present, else streams + background-caches
  (<200 MB gate is about bandwidth, not storage). Dead code removed with this:
  `LocalCacheStore.releaseAllHiddenChats/Messages` (C61 replaced release-all).
- **Attachment sends are optimistic bubbles now** (the old "no bubble, snackbar
  only" model is gone). `ThreadController.sendAttachments`: per staged file →
  `MessageModel.optimisticAttachment` (attachment guid `local-<tempId>`, bytes
  pinned in MediaCache under that key so it renders instantly; images inline,
  other kinds as file cards), upload progress via `_ProgressMultipartRequest`
  (api_client) → `uploadProgressOf(tempId)` ValueNotifier → `_UploadProgressBadge`
  ring on the bubble; failure → failed bubble + `_SendFailedBadge` overlay
  ("chat.notDelivered" l10n) with tap-to-retry (staged bytes kept in
  `_pendingAttachmentSends`). **No send:match for attachments** (server 202s) —
  reconciliation is by file identity: `attachmentSendMatches` + a 5-min window
  in `shouldReconcileLocalWithServer` (text stays 2-min). Confirmed media remains
  server-authoritative; the stable presentation key preserves the existing row
  while its attachment identity is updated.
- **New bubbles ease in** — `_BubbleEntrance` (240ms fade + 12% rise + 0.96
  scale). Every row is wrapped (so mid-animation rebuilds can't cut it); only
  unseen keys with a <15s timestamp animate, and the first loaded render seeds
  the baseline so history never animates.
- Tests: `attachment_optimistic_send_test.dart`. Client-only; needs an APK
  rebuild.

## Hidden-items restyle + persisted developer mode (C61, client-only)

- **Hidden messages / Hidden contacts pages** were rebuilt in the Settings style:
  one shared generic `_HiddenItemsPage<T>` (`settings_screen.dart`) renders a
  section-header + Card-of-tiles list inside its own `_SettingsSubPage` (which
  now takes AppBar `actions`). Multi-select lives in the **top-right as icons**
  (checklist enters select mode — tapping a row also does; then select-all +
  close). Each row has a per-item unhide IconButton (visibility icon) outside
  select mode; batch restore is a full-width bottom FilledButton with the count
  in its label (no "N selected" text). `HiddenMessagesPage`/`HiddenContactsPage` are
  thin wrappers supplying load/restore tear-offs + a row mapper; the old
  `_HiddenSelectionBar`/CheckboxListTile list is gone. New l10n:
  `settings.select` / `settings.selectAll`.
- **Developer mode (7 taps on the About version row) is persisted**:
  `AppController.developerModeEnabled` + `setDeveloperModeEnabled` (SecureStore
  `micago.developer_mode.v1`, loaded in `_loadNotificationPreferences`, which
  runs at bootstrap + restore-reload). The Settings "More" card and `_AboutBody`
  both read it off the controller — previously it was ephemeral
  `_SettingsScreenState` state, so leaving Settings hid the entry again.
  Disable stays where it was: About → status row → confirm dialog.

## Video posters, device name, details media (C53)

- **Video thumbnails ("Invalid image data").** The client fetches a video's
  `getAttachmentPreviewBytes`, but the server was serving the raw mp4 → `Image.memory`
  failed. Now the server serves a **Quick Look poster frame**: `GetAttachmentPreview`
  routes videos through `renderOrientedPreview` (verified `qlmanage -t` extracts a
  real frame from .mov/.mp4), and `loadAttachmentsByMessageGUID` sets a `previewUrl`
  for videos (`store.IsVideoAttachment`). Needs the **backend rebuilt**; the client
  already renders the preview + play overlay. Test:
  `TestListChatMessagesVideoGetsPosterPreviewURL`.
- **Companion Paired Devices.** `ActiveConnectionInfo.subtitle` no longer shows the
  client runtime ("flutter"). The row title is the client's registered `name`, which
  the client now sets to the **real device name** via `device_info_plus`
  (`resolveDeviceName`: iOS `iosInfo.name` — note iOS 16+ returns a generic "iPhone"
  without a special entitlement; Android `"{manufacturer} {model}"`). Cached once in
  `AppController._resolveDeviceName`.
- **Chat details media grid.** Shows **11 recent photos/videos, stickers excluded**
  (`!isStickerLike`); a 12th **"+N / Show all"** tile appears when there are more and
  opens `_AllMediaScreen` (full-screen grid of every shared photo/video). New l10n
  `chat.media` / `chat.showAllMedia`.
- **Details entry.** Tapping the header **name/avatar** (`titleRow` wrapped in a
  `GestureDetector`) opens details; the top-right info button is removed (both the
  embedded pane header and the phone `AppBar`).

## FCM notification content: name + avatar + text (C60)

- **Message text in the push.** The server only includes body text when
  `notifications.preview == "sender_and_text"`, and the Companion **hardcoded
  `preview: "sender"` on every save** — so pushes never carried content. Fixed:
  the Companion's Firebase card has a **Notification preview picker**
  (sender_and_text / sender / none, `NotificationsView.swift` +
  `AppModel.saveNotificationsConfig` passes `notifPreview`), and the server
  default for fresh configs is now `sender_and_text` (`config.go`). **Existing
  configs keep their written `preview: sender`** — flip it in the Companion and
  Save.
- **Contact name + avatar in the FCM background isolate.** The isolate can't
  reach ContactsService, so the main isolate persists a **handle → {name,
  avatar-file} cache** (`notification_contact_cache.dart`, SecureStore key
  `micago.notif_contact_cache.v1`, capped 300): `AppController.
  syncNotificationContactCache` runs after each chat-list load (throttled 10 min),
  resolving names via `contactNameResolver` and writing contact photos to
  **app-support**/notif-avatars (not the purgeable temp dir); custom avatars win.
  `showPushNotification` looks the handle up, overrides the sender/conversation
  title for 1:1 chats, and passes `avatarFilePath` (existence-checked) into the
  MessagingStyle Person. Fallback stays server name → handle. Tests:
  `notification_contact_cache_test.dart` (encode/decode/normalize/cap).
- Needs: **Companion rebuild** (picker) + **backend rebuild** (default) + **APK
  rebuild** (cache + isolate lookup); then set preview to "Sender & message" in
  the Companion and Save.

## FCM push: dropped fcm re-registration (C58)

- **Root cause of "app + server both say registered, but no push".** On startup
  `connectForeground` registers the device with `pushProvider='none'` (the token
  isn't fetched yet). While that multi-candidate call is in flight, `PushService`
  obtains the FCM token and calls `updatePushRegistration(provider:'fcm')` →
  `_registerDeviceIfPossible()` → hit the `_registerInFlight` guard → **silently
  dropped**. Server keeps provider=none/no token → dispatcher never pushes; UI
  still shows "registered". Race-dependent → the "works sometimes" symptom.
- **Fix:** the in-flight guard now sets `_registerRerunQueued` instead of
  dropping; the `finally` runs one coalesced re-register that reads the
  then-current push state (`app_controller.dart`). Any later registration also
  carries the fcm state since `updatePushRegistration` sets fields before
  registering.
- Verified-fine parts (don't re-litigate): background handler is registered
  first-in-`main()` (native callback-handle store needs no Firebase app;
  `start()` re-asserts it), server FCM payload is data-only + `android.priority:
  high`, background isolate re-inits Firebase from persisted options.
- Landing page (`docs/index.html`): logos were already wired; added a script that
  resolves **direct download URLs** for the latest release's `.apk`/`.dmg` via the
  GitHub API (asset names are versioned so `/releases/latest/download/<name>`
  can't be hardcoded); falls back to the releases page.

## Relay sync write-avoidance (C57)

- **Steady-state syncs no longer rewrite identical rows.** All three sync
  upserts (`upsertChatsTx` / `upsertMessagesTx` / `upsertAttachmentsTx`,
  `relaydb/sync.go`) carry a `DO UPDATE ... WHERE <column diff>`, so an
  unchanged conflict row is a no-write (`RowsAffected` 0). Written/unchanged
  counters flow through `SyncResult` into the status diagnostics
  (`lastChatsWritten` / `lastMessagesWritten` / `lastAttachmentsWritten` /
  `lastRowsUnchanged` / `lastLookbackApplied`). `chats.updated_at` only moves on
  real change (it's just an ORDER BY tiebreaker); `attachments.created_at` is
  **insert-only** (its `now` fallback used to churn every cycle and reorder the
  C49 dedup's `(created_at, guid)` key).
- The per-message `SELECT 1` existence probe is now one chunked `IN` query
  (`existingMessageGUIDsTx`, 500/chunk).
- **The C11 date-lookback recovery scan is throttled**: `lookbackGate` (app.go,
  `lookbackScanEvery` = 1 min) passes lookback 0 to `SyncOnce` on all other
  triggers, re-arming on sync failure. The ROWID watermark still runs every
  sync; `UpdatePass` cadence (read receipts/edits) is unchanged. Architecture
  unchanged — the API still serves relay.db, never chat.db.
- Tests: `relaydb/writeavoidance_test.go` (identical re-sync writes 0 rows +
  timestamps frozen; real change writes exactly that row; lookback-0 skips the
  date scan), `app/lookbackgate_test.go`. **Requires rebuilding the bundled
  backend.**

## Config parser → yaml.v3 (C56)

- `internal/config` now uses `gopkg.in/yaml.v3` (the module's 3rd dep) instead of
  the handwritten line parser/renderer; `fileConfig` carries `yaml:` tags.
  **The written byte format is unchanged and load-bearing**: the Companion's
  `ConfigReader.swift` and the smoke scripts' `sed 's/^  token: "\(.*\)"$/…/'`
  line-match it. `renderConfig` encodes via a `yaml.Node` pass that double-quotes
  string *values* (never keys) + re-inserts blank lines between sections —
  guarded byte-for-byte by `config_migration_test.go`
  (`TestLegacyConfigRoundTripsThroughNewRenderer` asserts render(parse(legacy)) ==
  legacy). Parsing keeps old semantics: absent keys → defaults, unknown keys
  ignored; malformed YAML now errors instead of being silently skipped.

## Connection security review + WS token in header (C55, v0.56.0)

- **Reviewed the client→server path**: REST + WS both bearer-auth'd. Server auth
  is constant-time (`crypto/subtle`), token is 256-bit `crypto/rand` hex, HTTP
  endpoints accept the token **only** in the `Authorization` header (never a query
  param); `--disable-auth` is refused off-localhost. AppleScript send escapes `\`
  and `"` and passes the script as a single `osascript -e` argv (no shell) → no
  injection. Attachment serving resolves symlinks and requires the path be under
  Attachments/StickerCache. SQL is parameterised (the two `Sprintf` cases are
  constant schema identifiers). All sound.
- **Fixed: the WebSocket sent the token as `?token=` in the URL** (leaks into
  access/proxy/tunnel logs). Native platforms now send it in the `Authorization`
  header via a conditional-import factory (`ws_channel_factory_io.dart` /
  `_web.dart`, imported with `if (dart.library.html)`); web keeps `?token=` since
  browsers can't set WS handshake headers. Server already accepts both.
- **Accepted tradeoffs (documented, not changed)**: LAN default is `http://` so
  the token/content are plaintext on-LAN (inherent to a self-hosted LAN app; the
  Cloudflare tunnel is HTTPS); the WS `InsecureSkipVerify:true` skips the Origin
  check but the token gates the upgrade so CSWSH isn't exploitable; first-run
  prints the token to stdout for headless pairing (the Companion redacts captured
  stdout, and it's also in the config file + pairing QR).

## Settings backup/restore + reaction/emoji polish (C54, v0.55.0)

- **`.micagobak` settings backup** (`core/backup/backup_service.dart`) — a plain
  zip (`archive` pkg): `manifest.json` + `settings.json` + `assets/` (chat
  background, custom avatars). Backs up **settings only** — the connection profile
  (baseUrl/routes/selected/**token**), appearance (theme/color/lang/chat bg),
  message-display prefs, contacts-match flag, muted list, keep-alive, custom
  avatars, sidebar width, and pin/hide + hidden-message tombstones. Never chat
  history, media caches, notif buffer, diagnostics, FCM token, or the **device id**
  (dropped on restore so the install re-registers as a *new* Paired Device).
  `inspect()` is static (validates manifest/version → summary); `applyBackup()`
  writes SecureStore keys, restores asset files (rewriting the chat-bg path),
  seeds `hidden_messages`, and stores pin/hide as **pending flags** the chat-list
  applies as chats sync (`applyPendingChatFlags`). Export warns that the file holds
  the token (v1 is unencrypted). Tests: `backup_service_test.dart` (inspect),
  `local_cache_store_test.dart` (flags round-trip).
- **Entry points**: Settings → *Backup & Restore* card (Export/Import), and the
  connection/pairing screen shows *Import settings backup* so a reinstall can get
  straight back in. Shared flow in `settings/backup_restore_ui.dart`; after restore
  it re-`bootstrap()`s Theme/MessageDisplay/Contacts controllers +
  `AppController.reloadAfterRestore()` (reload + reconnect + fresh device id).
- **Reaction chips visible on every bubble type** — on stripped/transparent
  bubbles (emoji, files, media) the chip sat on the chat background and its light
  surface colour blended in; added a shadow + kept the border/solid surface so it
  shows on any background (`_ReactionChips`).
- **Emoji bubbles** (≤3 emoji, bubble-less) get a little vertical padding — they
  were too cramped.

## Send effects — tap "Sent with …" to play (C52)

- **Effects never auto-play**; tapping a message's "Sent with …" label triggers
  them (`onPlayEffect` → `_playMessageEffect`). `MessageSendEffect`
  (`message_render.dart`) + `sendEffectFor(expressiveSendStyleId)` classify Apple's
  ids; `isScreenSendEffect` splits **bubble** effects from **screen** effects.
- **Bubble effects** animate the bubble in-place (`_EffectBubble`, per-effect
  duration + `HapticFeedback`): **Slam** drops in oversized + tilted then springs
  with a rattle; **Loud** pops big and trembles then settles; **Gentle** rises from
  tiny. **Invisible Ink** (`_InvisibleInkBubble` + `_InkPainter`) covers the
  message with shimmering dust until tapped — covered by default (authentic),
  tap the bubble to reveal, tap the label to re-hide.
- **Screen effects** play as a top overlay: **Confetti** stays on the `confetti`
  package; **Fireworks / Balloons / Love / Lasers / Celebration / Spotlight /
  Echo** are CustomPainter particle systems in `send_effects.dart`
  (`SendEffectController` + `SendEffectOverlay`, one per thread, `IgnorePointer`
  over the stack). Particles are generated once per play from a token-seeded RNG.
- Ported BlueBubbles-style. Tests: `bluebubbles_semantics_test.dart` covers the
  id→effect mapping + screen/bubble split. Client-only.

## Scroll performance in image/file-heavy threads (C51)

- **`imageByteCache` was an unbounded global `Map<String,Uint8List>`** — it held the
  raw encoded bytes of every image ever scrolled past, on top of Flutter's decoded
  cache, so a media-heavy thread grew memory without limit and the GC pressure
  showed as scroll jank. Now a **bounded LRU by total bytes** (`LruByteCache`,
  48 MB, `media_viewer.dart`) with the same `cache[key]`/`cache[key]=` interface,
  so call sites are unchanged.
- **Decode at the size shown, not a fixed 900 px.** `_ImageAttachment` now sets
  `cacheWidth = (displayWidth × devicePixelRatio)` clamped to ≤900 (only ever
  *smaller*), plus `filterQuality: low` — less decode CPU + memory per thumbnail.
- **No spinner flash on scroll-back.** `_ImageAttachment`/`_StickerAttachment` read
  already-cached bytes **synchronously** in `initState` and render immediately,
  instead of going through a `FutureBuilder` loading frame each time a row recycles.
- Media-bearing rows already get a `RepaintBoundary` (`_buildRow`). Client-only.

## Duplicated attachments (real root cause) + thread layout + QR (C49/C50)

- **"Every photo / file / sticker / voice clip shows up twice — only *old*
  messages, not freshly-sent ones."** Root cause is **server-side, in the data**,
  not the render. A real chat.db carries several `attachment` rows (DISTINCT guids)
  for one underlying file — duplicate `message_attachment_join` entries, or
  Messages re-creating the record — and `attachmentBaseSelect`
  (`store/queries.go`: attachment ⋈ message_attachment_join ⋈ message) surfaced
  them all. relay.db keeps them (its `attachments.guid` PK only collapses *same*
  guids), so the client got two attachments for one file. New messages were clean,
  which is why only history duplicated. A guid-only dedup can't catch this.
- **Fix: dedup by file identity, not guid.** Server `loadAttachmentsByMessageGUID`
  (`relaydb/query.go`) now collapses, per message, rows with the same
  `attachmentIdentityKey` = transfer/file name + total_bytes + mime_type (keeps the
  first by `created_at, guid`). This serves both the messages page and the delta,
  so it fixes already-synced history without touching the DB. Client mirrors it:
  `MessageModel.fromJson` dedups via `_attachmentIdentityKey` (same key shape;
  falls back to guid when there's no name) as a safety net for already-cached rows.
  Tests: `query_test.go` `TestListChatMessagesDedupesDuplicateAttachmentFiles`,
  `message_model_test.dart` "dedupes duplicate attachment records for the same file".
- **C50 thread layout (re-applied — these were *not* the duplication cause).**
  - **Mixed photo+caption now splits into two visual siblings** — media as a
    bubble-less block, the caption in its own chat bubble — instead of one merged
    bubble (`_MessageBubble`: `mixedMediaText`, the `paint()` helper).
  - **Dynamic bottom inset.** The composer + staged strip + open emoji/attachment
    panel live in a `Positioned(bottom:0)` overlay over the list; the list padding
    was a fixed `104` so panels hid the newest messages. `_bottomInset(context)`
    now adds the live panel heights (`AttachmentPanel.panelHeightFor` /
    `EmojiPanel.initialHeightFor`); the jump-to-bottom button rises with it.
  - **Keyboard inset residual.** Backgrounding with the keyboard up left a blank
    gap above the composer on resume. `didChangeAppLifecycleState` now unfocuses on
    inactive/paused/hidden and `setState`s on resume.
- **QR pairing camera (C62 model — supersedes C49/C59).** Every earlier
  "authorized but the camera never opens" came from *us* driving `start()`
  (initState/post-frame/retry loops) racing the widget's attach + swallowing
  start() exceptions into a silent black preview. Now **the MobileScanner
  widget owns the session** (`autoStart:true`: it start()s after its own
  attach, stop()s in its dispose — mount/unmount via the pairing stage is the
  on/off switch), and the screen State only handles app pause/resume (external
  controllers don't get the plugin's lifecycle handling) and **cold-restart
  recovery**: Retry swaps in a brand-new controller under a new `ValueKey`,
  strictly sequenced (unmount old → await endOfFrame → dispose old → mount
  new) because the platform channel is a singleton whose dispose() stops the
  active camera, and a live widget must never be rebound (C59 blank-preview
  lesson). The error card shows the raw plugin `errorCode` for diagnosis —
  which is what finally cracked it: **release builds crashed with an obfuscated
  NPE (`qc.b.a(mc.b)`) because R8 full mode stripped ML Kit barcode internals**
  (debug builds worked; mobile_scanner's consumer rules only keep
  `com.google.mlkit.*` — single star, no subpackages, no gms internals). Fixed
  in `android/app/proguard-rules.pro` (keep `com.google.mlkit.**` +
  `gms.internal.mlkit_*` + barhopper + odml) wired via `proguardFiles` in
  `build.gradle.kts`; verified in the release mapping (classes map to
  themselves). Camera-related release crashes ⇒ check R8 first.
- Client changes need an **APK rebuild**; the attachment dedup also needs the
  **backend rebuilt**. Reminder: the C48 orientation fix is server-side too —
  qlmanage is verified correct for HEIC *and* JPEG (orientation 6/8 → upright), so
  a still-rotated HEIC means the backend binary wasn't rebuilt.

## Image orientation: qlmanage, not sips (C48)

- **Root cause of "iPhone HEIC photos render rotated 90° in our app but upright
  everywhere else".** The server preview converter used
  `sips -s format png` (`GetAttachmentPreview`, `handlers.go`). **`sips` copies the
  stored pixels and drops the EXIF orientation tag** — it does *not* bake the
  rotation in (verified on this Mac: a 100×200 photo with EXIF orientation 6 stays
  100×200 instead of becoming the displayed 200×100; `--resampleHeightWidthMax`
  doesn't help either). So every HEIC (which always goes through this converter,
  since Flutter/Skia can't decode HEIC on Android) came out rotated.
- **Fix: `renderOrientedPreview` uses Quick Look (`qlmanage -t -s 4000 src -o
  dir`)**, which bakes EXIF orientation into the PNG (verified orientation 6 and 8
  → correct 200×100; normal images unchanged; no upscaling). qlmanage exits 0 even
  when it can't render, so success is judged by whether it actually wrote
  `<basename>.png`; the file is then moved to the cached `previewPath`.
- **Conversion scope = HEIC/HEIF/TIFF + JPEG; PNG stays direct.** HEIC/TIFF must
  convert (Skia can't decode them); JPEG is added because iPhone photos bake their
  rotation into EXIF orientation and some were still rendering sideways on the
  client — the Quick Look preview bakes orientation into the pixels so every device
  agrees. (Trade-off: JPEG→PNG is larger, but previews are cached after first view.)
  PNG has no EXIF orientation and is web-renderable, so it's served raw.
  `NeedsPreviewConversion` / `attachmentNeedsPreviewConversion` carry this set;
  tests: `TestAttachmentPreviewConversionScope`,
  `TestDecorateAttachmentJSONRoutesJPEGThroughPreview`.
- **Duplication ("stickers / photos / attachments each render twice").** Came from
  an uncommitted experiment in `message_thread_screen.dart` (a "split mixed
  media+text" bubble path + a `threadImages` gallery rework + scroll-padding
  helpers). The whole experiment was **reverted to the committed baseline**
  (`git checkout HEAD -- message_thread_screen.dart`, plus its helper edits in
  `attachment_panel.dart` / `url_preview.dart` and an orphan `url_preview_test.dart`).
  C47 lives in HEAD, so the revert keeps it. Every inline render site, the row
  collapsing (`buildDisplayRows`), `MessageCollection` dedup, and the attachment SQL
  were each verified to render an attachment exactly once — so the duplication was
  purely the experimental layout.
- **Requires rebuilding the bundled backend** (preview command change) **and the
  Flutter app** (the revert). Quick Look is a system binary (`/usr/bin/qlmanage`)
  present on every Mac. Version bumped to **0.51.0** (Go, Flutter pubspec +
  `kAppVersion`, Companion `MARKETING_VERSION`).

## Unread dot: ingestion never clears it; thread owns "seen" (C47)

- **Root cause of "a new message makes an existing red dot disappear" + merged-chat
  flakiness.** `seen` was computed at *ingestion* time as
  `isFromMe || (isForeground && isChatActive(guid))` (WS `_patchMessage` + delta
  `runDeltaSync`). `isChatActive` reads a single mutable `_activeChatGuid`, which
  goes stale across phone push/pop, two-pane, deep-links, and resume — so an
  arriving message could be wrongly treated as *seen*, advancing the read
  watermark and **clearing a dot that should stay lit**. For merged contacts the
  active guid is only ever one route, so it was inconsistent too.
- **Fix: ingestion only ever lights (or leaves) the dot — it never advances
  another party's watermark.** Both ingestion paths now use `seen = msg.isFromMe`.
  Marking a chat read is owned **exclusively by the open thread**
  (`AppController.markChatsViewed` → `cache.markChatsSeen` + a new `chatSeen`
  broadcast the chat list listens to → re-derives the dot from cache immediately,
  important for the tablet two-pane where the list stays visible).
- **`MessageThreadScreen` is the single "user is looking at this" authority.** It
  marks every route viewed on open, on each arriving message (subscribes to
  `deltaMessages` + `ws.events` filtered to its route guids — covers non-active
  routes of a merged contact), on route switch, and on app **resume** (via a
  `WidgetsBindingObserver`) — all gated on `app.isForeground` so a backgrounded
  arrival with the thread mounted still lights the dot.
- **Race-proofing.** `markChatsSeen(guids, {upTo})`: the thread passes the
  observed message timestamp, so the watermark advances past it even if the list
  ingestion hasn't bumped `latest_renderable_at` yet (either write can win). It
  also never regresses the watermark (`max(latestAt, lastSeenAt, upTo)`).
- `setActiveChatGuid`/`isChatActive` survive only for the dispose cleanup; they no
  longer gate the dot. Tests: `local_cache_store_test.dart` (`upTo` race + no
  regress). Client-only change — no backend rebuild.

## Chat-list timestamp format (C46)

- The trailing time is no longer a forever-growing countdown. `chatTimestampLabel`
  (pure, top-level in `lib/features/chats/message_render.dart`) buckets it:
  `<1min`→"now", `<1h`→relative "5m", **same day >1h**→clock time (e.g. `06:06`),
  **within 7 days**→weekday name ("Monday"), **older**→numeric date ("5/20/2026").
- Locale-aware via `intl` `DateFormat` (`.Hm`/`.jm`/`.EEEE`/`.yMd`); 12h vs 24h
  comes from `MediaQuery.alwaysUse24HourFormat`, locale from
  `Localizations.localeOf(context).languageCode`. `intl` is now a **direct** dep
  (was transitive via flutter_localizations) so it can be imported.
- `_formatTime` in `chat_list_screen.dart` is just a thin wrapper that reads
  `use24h`/`locale` from context and delegates. The function has a
  locale-independent fallback (clock / English weekday / `M/D/YYYY`) if date
  symbols aren't loaded, so it never throws. The 60s heartbeat (C45) re-renders
  these as time passes.
- Unit tests: `test/chat_timestamp_test.dart` (`setUpAll` calls
  `initializeDateFormatting`; flutter_localizations does this on-device). intl
  uses a narrow no-break space before AM/PM — tests normalize it.

## Unread dot: background fix + row polish (C45)

- **Root cause of "message refreshes on resume but no red dot" (phone).** A message
  arriving while the app was **backgrounded** was still treated as *seen* if a chat
  thread was open underneath — `seen = isFromMe || isChatActive`. That advanced the
  read watermark (`bumpChatWithMessage(seen:true)`), so the preview updated but the
  derived dot (`latestRenderableAt > lastSeenAt`) stayed off. Fixed in **both**
  ingestion paths (WS `_patchMessage`, delta `runDeltaSync`):
  `seen = isFromMe || (isForeground && isChatActive(guid))`. A backgrounded arrival
  is never "seen" → it lights the dot even with a thread left open. (Foreground on
  the list already worked, which matched the symptom.)
- **Alignment.** The trailing column is now centre-aligned so the unread badge sits
  on one vertical line directly under the timestamp (the badge's transparent
  hit-padding had nudged a right-aligned badge off the time's right edge).
- **Auto-refreshing time + safety net.** `_ChatListScreen` runs a 60s heartbeat:
  re-renders the relative timestamps ("now"→"1m"→"2h") and, when foreground +
  connected, silently `load()`s the chat list so the dot self-heals within a minute
  even if a realtime event was dropped (mobile WS drops).

## Chat-row crash fix + cleanup (C44, backend v0.36)

- **White-screen fix.** The chat row used a `ListTile` whose `trailing` (time +
  draggable badge) could be reported full-width → "Trailing widget consumes the
  entire tile width" layout assertion → blank home page. Rebuilt `_ChatRow` as a
  custom `Row` (`InkWell` + avatar + `Expanded` title/preview + trailing column),
  so there's no `ListTile` trailing-width constraint. Same visual spec (tinted
  rounded card for numbered unread, plain dot otherwise).
- **Badge controller crash fix.** `_DraggableUnreadBadge` held the spring
  `AnimationController` in a **lazy** `late final = AnimationController(...)`. When
  the badge was removed the same frame it appeared, the field was first constructed
  inside `dispose()`, which touches an inherited widget (`TickerMode`) on a
  deactivated element → "Looking up a deactivated widget's ancestor is unsafe."
  Now created eagerly in `initState`.
- **Dead-code cleanup.** Removed the zero-caller `ChatListController.hideChat`
  (single) and `ChatListController.alwaysShowChat`. Kept `setChatAlwaysVisible`
  (still tested + part of the hidden-chat filter).
- Versions bumped to **0.36.0** (Go, Flutter pubspec + `kAppVersion`, Companion).

## Watermark-derived unread dot (C43)

- **The home unread dot is now derived from chat data, not a live counter.**
  Replaced the fragile "increment `unreadCount` only on WS/delta `message:new`"
  model (which missed app-closed / FCM-wake / reconnect cases) with BlueBubbles'
  rule, computed on every refresh:
  `hasUnread = latestRenderableAt > lastSeenAt && !latestRenderableFromMe`.
- **Server:** `ChatJSON.latestRenderableFromMe` (added to the `ListChats` query —
  the `is_from_me` of the latest renderable message). Additive; no version bump.
- **Client cache (schema v5):** new `chats.last_seen_at` + `chats.latest_from_me`
  columns. `last_seen_at` is seeded to the chat's latest **only on first insert**
  (existing history starts "seen"); `bumpChatWithMessage` advances
  `latest_renderable_at`/`latest_from_me` but leaves the watermark behind unless
  `seen` (my message OR the chat is open); `markChatsSeen` catches the watermark up
  (open / mark-read / badge-drag). `_chatFromRow` derives `hasUnread`. `load()` now
  displays from the cache (filtered to the server's guids) so reload/delta/resume/
  pull-to-refresh all agree.
- **Decoupled from notifications entirely** — FCM/WS/keep-alive never gate the dot.
  `ChatSummary.hasUnread` is the source of truth; `unreadCount` is only the badge
  number. Visuals: `hasUnread && count>0` → tinted rounded card + red number pill;
  `hasUnread && count==0` → plain accent dot, no tint; `!hasUnread` → normal row.
- **Draggable badge** (`_DraggableUnreadBadge`): long-press the badge to grab, drag
  it away; past ~44px on release → `markRoutesRead` (advances `lastSeenAt`, dot
  clears); under → elastic spring-back. Doesn't open the chat (long-press gesture,
  no scroll conflict).
- **Deleted** the old `clearUnreadForChats` / `setChatUnreadCount` / `unreadCounts`
  cache methods and the `load()` unread-overlay.

## Pin/hide + test-contact Debug card (C42, backend v0.34)

- **Test contact, two-way via the Companion Debug card.** New
  `POST /api/test-contact/inbound` injects a message *from* the test contact
  (`is_from_me=0`) + broadcasts `message:new` → pushes to the phone like a received
  iMessage (`internal/relaydb/testcontact.go` `AppendTestInboundMessage`; handler in
  `internal/httpapi/testcontact.go`). The Companion's **Message Inspector** (Debug)
  has a `TestContactDebugCard` pinned at the top: a 2-way scratchpad (text field →
  inbound; the phone's loopback replies poll in via `GET /api/chats/{guid}/messages`).
  Each **server (re)start resets** the conversation to just the greeting
  (`ResetTestContactMessages`, called from `app.Run`).
- **Sync Control ↔ Debug alignment.** `RecentMessagesCard` now fetches
  `messages/recent?debug=true` (the full raw set — no silently dropped rows) and
  shows a bracketed placeholder (`[图片]`/`[视频]`/`[语音]`/`[贴图]`/`[文件]`, via
  `RecentMessage.previewLabel` + `RecentAttachment.placeholder`) instead of a blank
  "(no text)" row.
- **Client pin/hide (chat-level + message-level), all client-only.** Cache schema
  **v4**: `chats.pinned` column + a `hidden_messages` tombstone table (kept out of
  the messages table so a server re-sync's delete+reinsert can't resurrect a hidden
  message). Chat list: **swipe right = clear the unread dot, swipe left = hide**
  (`Dismissible`); **long-press = Pin/Unpin or Hide** (`_showChatMenu`). Pinned chats
  sort to the top (`ORDER BY pinned DESC`). Thread: long-press a message → **Hide**
  (`MessageAction.hide` → `ThreadController.hideMessage`). Settings → **Hidden items**:
  "Release hidden messages" + "Release hidden contacts" (`_HiddenItemsCard`).
- **Fixed a latent bug:** `upsertChats` used `ConflictAlgorithm.replace`, which
  delete+reinserts and **reset the flag columns** (`hidden`/`always_visible`/`pinned`)
  on every server refresh. Switched to `INSERT … ON CONFLICT(guid) DO UPDATE` that
  only rewrites json/timestamp, so the flags persist.
- **Requires rebuilding the bundled backend** (new endpoint + reset-on-start) and the
  client (schema v4 rebuilds the cache).

## Unread badges (C41)

- The chat-list card shows a circular unread count (`_UnreadCountPill` in
  `chat_list_screen.dart`). The count is **client-tracked** — the server's
  `ChatJSON` does not carry unread.
- **Ownership:** the local cache holds the count. `bumpChatWithMessage(markUnread:)`
  increments on an incoming WS `message:new`; the list's `markRoutesRead` (run from
  `_openMerged`, the single thread-entry point for both panes and notification
  deep-links) clears on open; `_switchRoute` clears a sibling route on switch.
- **The bug that was fixed:** `load()` displayed the raw server list (no unread), so
  every reload wiped the badges even though `upsertChats` preserved the count in the
  cache. `load()` now overlays the cached counts (`LocalCacheStore.unreadCounts()`)
  onto the authoritative server result — badges survive reloads, and chats the
  server drops still disappear (don't read the whole list back from cache, which
  never prunes).
- **Idempotent increment:** `_patchMessageEvent` checks `hasMessageGuid` **before**
  the upsert and only marks unread for a genuinely new guid, so a replayed WS event
  can't over-count.
- **Cleanup:** removed the redundant unread-clear in `MessageThreadScreen.initState`
  (the list's `markRoutesRead` already clears every open). `setActiveChatGuid` keeps
  the open route from re-incrementing while on screen.

## Offline test contact (C40)

- A self-contained **loopback test contact** (`test@micago.cinmou` — a domain
  that does not resolve, so nothing can ever be delivered). Lets you exercise the
  chat/notification pipeline without messaging a real person.
- **Server** (`internal/testcontact` constants + `internal/relaydb/testcontact.go`):
  a synthetic chat `iMessage;-;test@micago.cinmou` upserted into relay.db with a
  seeded inbound greeting. `SetTestContactEnabled` seeds/removes it; the on/off
  flag lives in `sync_state` (`test_contact_enabled`). Synthetic message rows use
  **NULL `source_rowid`** on purpose — the delta cursor is `MAX(source_rowid)`, so
  a synthetic rowid would corrupt real incremental sync; NULL keeps them out of
  the delta watermark entirely (they still show on chat open via `date_created`
  and live over WS). Endpoints: `GET/PUT /api/test-contact`.
- **Send interception** (`internal/httpapi`): `SendText` branches to
  `sendTestLoopback` for the test chat **before** any AppleScript/Messages
  machinery — it records the message as a delivered outgoing row and confirms it
  over the normal `send:match` path. `SendAttachment` rejects the test chat
  (text-only). Nothing ever reaches Messages.app. No auto-reply (record-only).
- **Client**: a **Settings → Testing** switch (`_TestContactCard`,
  `AppController.setTestContactEnabled` → `PUT /api/test-contact`). Enabling
  broadcasts the greeting as `message:new`; the chat-list controller reloads via a
  new `AppController.chatListReloads` signal (also fired on disable) so the chat
  appears/disappears without a manual refresh. New l10n: `settings.testing` +
  `settings.testContact*`.
- **Requires rebuilding the bundled backend** (new endpoints + send interception)
  and the client.

## Sticker bytes not served (C39)

- **Client showed "贴纸" but no image** because the sticker's file lives in
  `~/Library/Messages/**StickerCache**/…` — a **sibling** of `Attachments`. The
  `resolveAttachmentPath` guard (`internal/httpapi/handlers.go`) only allowed paths
  **under** `attachmentsRoot`, so it 404'd the sticker. Fixed: allow the
  `StickerCache` sibling too (`stickerCacheRoot`), guard still restricts to those
  two Messages subdirs. Verified live: `GET /api/attachments/{guid}` → 200 image/png
  served straight from StickerCache. Test: `internal/httpapi/sticker_path_test.go`.
- Also made sticker **preview conversion format-driven** (`NeedsPreviewConversion` /
  `attachmentNeedsPreviewConversion` no longer force-convert every sticker) — a PNG
  sticker serves as-is; only HEIC/TIFF convert.
- Removed the long-press **Message Info** entry (`MessageAction.info`) from
  `showMessageActionMenu`; the `_SystemRow` tap-to-diagnose stays. Tests updated.
- Requires rebuilding the bundled backend.

## Stickers / location / handwriting (C37, backend v0.32)

- See [MicaGoServer/docs/stickers-location-handwriting.md](MicaGoServer/docs/stickers-location-handwriting.md).
- **Server** (`internal/store/attachmentkind.go`): stickers also detected by UTI
  (`com.apple.sticker`/`*.sticker`) not just the `is_sticker` flag; new
  `AttachmentKindLocation`/`DisplayKindLocation` from vlocation
  (`text/x-vlocation`/`public.vlocation`/`.loc.vcf`). Tests in
  `attachmentkind_test.go`.
- **Client**: `_LocationAttachment` card (fetch vlocation → extract Maps URL →
  Open in Maps via url_launcher); `MessageModel.isHandwritten`/`isDigitalTouch`
  (balloon ids) + sticker-only/embedded-media → **transparent bubble**
  (`stripBubble` in `_MessageBubble`). New l10n: `chat.location`/`openInMaps`/
  `handwritten`/`digitalTouch`.
- **Voice send (shipped)**: `record: ^6.1.1` + `RECORD_AUDIO` + **minSdk→23**
  (record 6 needs API 23; `maxOf(flutter.minSdkVersion, 23)`). `voice_recorder.dart`
  records AAC/m4a to a temp file; the composer's voice button records, a
  `_VoiceRecordingBar` (timer + Cancel/Send) replaces the input, Send → existing
  `sendAttachments`. No server change (send-attachment already sends audio).
  **Needs device verification** (mic capture + delivery can't be tested in CI).
  Note: `record 5.x` had a broken transitive set (`record_linux 0.7.2` predates the
  interface it pulls) — must use record 6.x+.
- Fixed a pre-existing `test/widget_test.dart` compile error (fake `SecureStore`
  was missing `deleteValue`).
- Requires rebuilding the bundled backend for the server classification.

## Sync Control "Server returned HTTP 500" header (C36)

- **Page loads fine, but a stale "Server returned HTTP 500." stays in the Sync
  Control header.** `model.lastError` is a global catch-all, and the 3s background
  poll (`AppModel.refresh`) set `lastError` from its best-effort diagnostic fetches
  (`status`/`connections`/`devices`/`urls`). `lastError` is displayed in exactly
  ONE place — the Sync Control header (`SyncControlView.swift:25`) — so any poll
  500 (typically a **stale v0.26 bundled backend** on real data) showed up there.
  Fixed (client-side, robust to any endpoint): the poll now records diagnostic
  failures in `lastPollError` (Debug/Copy-diagnostics only) and clears `lastError`
  once reachable + authed; token-rejected + failed user actions still set
  `lastError`. Server endpoints themselves are robust (all 200 live). Rebuilding
  the backend to v0.30 removes the underlying 500 too. Companion change only —
  rebuild the Companion.

## Menu-bar "Open Dashboard" looked different (C35)

- **Dock/normal launch looked native; opening from the menu bar gave a different
  titlebar/toolbar (title shown in titlebar, controls collapsed).** Two window
  paths: the Dock/normal path uses the SwiftUI **`WindowGroup`** (`openWindow(id:)`),
  but the AppKit `NSStatusItem` menu (`MenuBarStatusItemController.openDashboard`)
  called `presentDashboardFromAppKit()` → a **hand-rolled `NSWindow`**
  (`DashboardWindowPresenter`) hosting `ContentView` in `NSHostingView`, which
  doesn't get SwiftUI's WindowGroup toolbar/titlebar treatment. Fixed: ContentView
  stores its `openWindow` action in `DashboardWindowOpener.shared` on appear, and
  `presentDashboardFromAppKit()` now (1) fronts an existing window, else (2)
  reopens the **same WindowGroup window** via that action; the hand-rolled NSWindow
  is only a last-resort fallback (launched-hidden-and-never-shown). Requires
  rebuilding the Companion. (Can't visually verify here — confirm the menu-bar
  window now matches the Dock one.)

## Link-preview "small files" above a URL (C34)

- **Sending/receiving a link showed 2–4 tiny "file" cards above it, but the
  server debug view didn't.** Apple marks a rich link's internal preview parts
  (site thumbnail, favicon, LinkPresentation payload) with **`hide_attachment=1`**.
  The messages API's `loadAttachmentsByMessageGUID` (`internal/relaydb/query.go`)
  never read or filtered `hide_attachment` — it only skipped no-MIME payloads via
  `IsAttachmentPreviewPayload` — so the thumbnail/icon (which have real `image/*`
  MIME) leaked to the client. Fixed: select `hide_attachment` and skip rows where
  it's set (matches the debug view + BlueBubbles, which exclude hidden
  attachments). Verified live (a `https://…` message returns only the real photo)
  + regression test `TestListChatMessagesExcludesHiddenAttachments`. **Requires
  rebuilding the bundled backend.**

## Sync Control timeout (C33)

- **"chats — The request timed out" / sporadic HTTP 500 with a healthy server:**
  relay.db had **no indexes**, so `ListChats` (`internal/relaydb/query.go`) ran its
  7 correlated per-chat subqueries as full scans of `messages` — O(chats × messages)
  — and blew past the Companion's **4s** request timeout on a real DB. Fixed:
  added `idx_messages_chat_date`/`idx_messages_source_rowid`/`idx_messages_date_created`/
  `idx_attachments_message_guid` in `internal/relaydb/migrations.go` (verified the
  planner now does `SEARCH … USING INDEX idx_messages_chat_date`); bumped the
  Companion request/resource timeout 4s→20s (`Services/APIClient.swift`); and
  `loadSyncControl` now clears the stale `lastError` so a leftover "HTTP 500"
  header no longer contradicts the timeout card. **Requires rebuilding the bundled
  backend** (indexes created on next start, migrations idempotent).
- **FCM self-test + remote push:** [docs/notifications-setup.md](docs/notifications-setup.md)
  has a step-by-step "Test FCM push end-to-end yourself";
  [docs/remote-access-cloudflare.md](docs/remote-access-cloudflare.md) explains push
  over the tunnel (push is Google→device; the tunnel is for the follow-up delta sync
  when off-LAN).

## Companion + server views (C32)

- **Root cause of "Sync Control 500" + "Paired Devices broken":** the chat.db
  sync reader scanned the flag columns (`is_from_me`/`is_read`/`is_delivered`/
  `cache_has_attachments`) into a plain `int64`; real chat.db stores these as
  **NULL** on many rows → `converting NULL to int64 is unsupported` → the
  **startup sync failed → `app.Run` returned the error → `log.Fatal` → the server
  never served.** Fixed: scan into `sql.NullInt64` (NULL→false) at both sites in
  `internal/store/queries.go`, plus made the **startup sync non-fatal**
  (`internal/app/app.go` — log + record `lastSyncError`, keep serving cached
  relay.db). Both endpoints' chains are otherwise correct (verified live: register
  → `/api/devices` → Companion decode all return 200). Regression test:
  `internal/store/queries_nullflags_test.go`.
- **Reproduce live:** `go build -o /tmp/micago ./cmd/micago`; run with
  `HOME=<tmp>` + a SQLite `chat.db` carrying the chat.db schema (see the store
  test DDL) — empty/0-byte chat.db aborts startup; a NULL `is_read` row used to.
- **Companion sidebar (`ContentView.swift`):** native `NavigationSplitView` with
  `.listStyle(.sidebar)`; **Settings + Debug + Log pinned at the bottom** via
  `.safeAreaInset(edge: .bottom)` (second sidebar List sharing `nav.selection`).
  "Advanced" relabeled **Settings** (`gearshape`). No fake title bars/traffic
  lights exist (window uses a real `.titled` styleMask); toolbar controls already
  trailing (`.primaryAction`).

## Chat UX (C32) — app renamed micaGO

- **Notifications are Android MessagingStyle**, grouped/stacked **per chat**
  (`notificationIdForChat`), with contact name + avatar. A small per-chat preview
  buffer (`notification_store.dart`, secure storage, cross-isolate) drives the
  stacking, dedups by message guid, and is cleared on chat open
  (`cancelChatNotification` via `requestOpenChat`). Avatar = on-device contact
  photo (keep-alive path, temp bitmap file) else monogram. **Reply action removed
  this pass.**
- **Stickers:** `AttachmentView` routes `isStickerLike` to `_StickerAttachment`
  first → renders the image, else a clean `_StickerPlaceholder` ("Sticker" chip),
  never a broken file card.
- **Media viewers** (`media_viewer.dart`): images get animated double-tap zoom;
  video gets play/pause/replay + time labels + show/hide controls.

## Notification path (C31)

- Three layers, each optional/fallback: **FCM push** (user-owned Firebase, wake-only) → **keep-alive** foreground service (local notifications, no Firebase) → **delta catch-up** (silent, never lost). See [docs/notifications-setup.md](docs/notifications-setup.md).
- **One presenter:** `lib/core/network/notification_display.dart` defines the channel/group/reply-action and `notificationIdForMessage` (a deterministic FNV-1a hash — **not** `String.hashCode`, which isn't stable across the FCM background isolate vs the main isolate). FCM and keep-alive notifications for the same message share this id → collapse into one (cross-path dedup).
- **Title = who, body = what.** Title resolution: on-device contact name (keep-alive/main isolate only) → server sender/title → raw handle → generic; never a GUID/empty (`messageNotificationTitle` in `push_logic.dart`). The server FCM payload now carries `handle`; `buildNotification` (`internal/notify/dispatcher.go`) sets title=sender, body=text only in `sender_and_text`.
- **Keep-alive notifications** come from `AppController._maybeNotifyBackgroundMessage` (fires on `message:new` only when backgrounded + keep-alive on). Local notifications now init **independently of Firebase** (`PushService._ensureLocalNotifications`).
- Diagnostics in Settings → Notifications: permission (Android 13+), last notification source, last reply result; copyable.

## Changed in this pass (Companion UI/state, C30)

1. **Menu-bar icon** (`MicaGoCompanionApp.swift`): `mica.error` for hard-failure states (not installed, crashed/unreachable); normal `mica` dimmed for inactive/transitional (stopped/starting/stopping); full-strength active for running/external. Template-rendered, no hard-coded colors.
2. **Menu-bar dropdown** (`MenuBarContent.swift`): removed the `LAN:`, `Public:`, and `Messages.app is running` rows. Kept Open Dashboard / Start / Stop (correct enabled state) / Keep Awake / Quit.
3. **Contacts permission** (`SyncControlView.swift`, `ContactsService.swift`): replaced the misleading disabled "Allow Contacts access" button with **Open System Settings** (`ContactsStore.openSystemSettings()`) + guidance that names/photos need permission while raw handles still work.
4. **Sync Control HTTP 500** path: investigated — all four handlers are correct and wired in source (`internal/httpapi`); a live 500 is environmental (commonly a stale binary; rebuild). Made the client resilient: per-endpoint loading (`AppModel.loadSyncControl`) so one failure doesn't blank the page and the error names which call failed; the client now surfaces the server's `{error:{code,message}}` body (`APIClient.validate(_:body:)`) instead of a bare status; and a proper **error card with Retry + Copy diagnostics** (`SyncControlErrorCard`) replaces the small inline line.
