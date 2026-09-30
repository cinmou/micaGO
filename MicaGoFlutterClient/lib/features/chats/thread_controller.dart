import 'dart:async';

import 'package:async/async.dart';
import 'package:flutter/foundation.dart';

import '../../core/app_controller.dart';
import '../../core/network/api_client.dart';
import '../../core/network/websocket_client.dart';
import '../../core/storage/media_cache.dart';
import 'attachment_panel.dart' show StagedAttachment;
import 'models/message_model.dart';
import 'realtime_event_helpers.dart' as rt;
import 'store/message_collection.dart';
import '../../core/l10n/app_localizations.dart';

enum ThreadState { loading, loaded, empty, error }

/// Drives one chat thread. Holds a [MessageCollection] (the per-chat store) and
/// *patches* it from REST pages + WebSocket events — it never reloads the whole
/// thread on an event when the payload is complete. Optimistic sends live in the
/// store and reconcile against later server rows.
class ThreadController extends ChangeNotifier {
  final AppController app;
  final String chatGuid;

  /// C68 (beta merged view): additional route guids displayed in this thread.
  /// Sends always go to [chatGuid]; these only widen what is *shown*.
  final Set<String> mergedGuids;

  ThreadController({
    required this.app,
    required this.chatGuid,
    Set<String> mergedGuids = const {},
  }) : mergedGuids = {...mergedGuids}..remove(chatGuid);

  /// Every chat guid rendered by this thread (primary + merged routes).
  Set<String> get threadGuids => {chatGuid, ...mergedGuids};

  static const int _pageSize = 50;

  ThreadState state = ThreadState.loading;
  String? error;

  final MessageCollection _col = MessageCollection();

  String? _historyCursor;
  bool _historyLoaded = false;
  bool hasMore = true;
  bool loadingOlder = false;

  /// C78: coalesces concurrent load() calls. There are seven triggers (start,
  /// pull-to-refresh, error retry, the debounced WS fallback, post-action
  /// refresh…), and each one used to clear + replace the whole message set, so
  /// two overlapping loads raced and the slower — possibly staler — one won.
  /// AsyncCache.ephemeral runs the body at most once concurrently and lets
  /// every caller await the same result (package:async, Dart team).
  final AsyncCache<void> _loadGate = AsyncCache<void>.ephemeral();

  /// C78: in-flight work must not touch a disposed controller (switching routes
  /// disposes this one while its load is still running).
  bool _disposed = false;

  StreamSubscription<WsEvent>? _wsSub;
  StreamSubscription<MessageModel>? _deltaSub;
  Timer? _reloadDebounce;

  /// Chronological (oldest → newest); the thread view renders it reversed.
  List<MessageModel> get messages => _col.ordered
      .where(
        (message) =>
            !app.messagePreferences.isHidden(
              '${message.chatGuid ?? chatGuid}\u001f${message.guid}',
            ) &&
            !app.messagePreferences.isHidden(message.guid),
      )
      .toList(growable: false);

  Set<String> _visibleHidden = {};

  void _onMessageVisibilityChanged() {
    if (_disposed) return;
    final hidden = app.messagePreferences.hidden;
    if (setEquals(hidden, _visibleHidden)) return;
    _visibleHidden = hidden;
    _notify();
    unawaited(_restoreCachedVisibleMessages());
  }

  Future<void> _restoreCachedVisibleMessages() async {
    try {
      final rows = await _cachedThreadMessages();
      if (_disposed) return;
      _col.mergeServerPage(rows);
      _notify();
    } catch (_) {
      if (!_disposed) rethrow;
    }
  }

  String presentationKeyFor(MessageModel message) =>
      _col.presentationKeyFor(message);

  void start() {
    app.messagePreferences.addListener(_onMessageVisibilityChanged);
    _wsSub = app.ws.events.listen(_onWsEvent);
    // C21: also patch from the delta catch-up (the correctness path), not only
    // WebSocket events. GUID dedup in the collection prevents duplicate bubbles.
    _deltaSub = app.deltaMessages.listen(_onDeltaMessage);
    unawaited(app.catchUp(reason: 'thread:$chatGuid'));
    load();
  }

  /// notifyListeners() that is safe after dispose (C78).
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  void _onDeltaMessage(MessageModel msg) {
    if (_disposed) return;
    if (!threadGuids.contains(msg.chatGuid) || msg.guid.isEmpty) return;
    _col.upsertServer(msg);
    _sweepAttachmentSendBookkeeping();
    state = ThreadState.loaded;
    _notify();
  }

  /// Cached messages for every guid this thread displays.
  Future<List<MessageModel>> _cachedThreadMessages() async {
    final combined = <MessageModel>[];
    for (final guid in threadGuids) {
      combined.addAll(await app.cache.listMessages(guid, limit: _pageSize));
    }
    return combined;
  }

  /// Refreshes the thread. Concurrent callers share one run (see [_loadGate]).
  Future<void> load({bool showSpinner = true}) =>
      _loadGate.fetch(() => _loadInner(showSpinner: showSpinner));

  Future<void> _loadInner({required bool showSpinner}) async {
    final api = app.api;
    if (api == null) {
      final cached = await _cachedThreadMessages();
      if (_disposed) return;
      if (cached.isNotEmpty) {
        _col.mergeServerPage(cached);
        state = ThreadState.loaded;
        error = null;
      } else {
        state = ThreadState.error;
        error = MicaLocalizations.current.t('common.notConnected');
      }
      _notify();
      return;
    }
    if (showSpinner && _col.isEmpty) {
      final baseline = _col.snapshot();
      final cached = await _cachedThreadMessages();
      if (_disposed) return;
      if (cached.isNotEmpty) {
        _col.mergeServerPage(cached, baseline: baseline);
        state = ThreadState.loaded;
      } else {
        state = ThreadState.loading;
      }
      error = null;
      _notify();
    }
    final baseline = _col.snapshot();
    try {
      final page = await api.getMessageHistory(threadGuids, limit: _pageSize);
      if (_disposed) return;
      await _cacheHistory(page.messages);
      if (_disposed) return;
      _col.mergeServerPage(
        page.messages,
        baseline: baseline,
        allowNewAttachmentFallback: true,
      );
      if (!_historyLoaded) {
        _historyCursor = page.nextCursor;
        hasMore = page.hasMore;
        _historyLoaded = true;
      }
      _sweepAttachmentSendBookkeeping();
      state = _col.isEmpty ? ThreadState.empty : ThreadState.loaded;
      error = null;
    } on ApiException catch (e) {
      if (_disposed) return;
      state = _col.isEmpty ? ThreadState.error : ThreadState.loaded;
      error = _humanize(e);
    }
    _notify();
  }

  Future<void> _cacheHistory(List<MessageModel> messages) async {
    for (final route in threadGuids) {
      await app.cache.mergeServerPage(
        route,
        messages.where((message) => message.chatGuid == route).toList(),
      );
    }
  }

  /// Synchronizes visibility for this message; the server retains its content.
  /// Re-reads the visible page from the cache so it disappears immediately.
  Future<void> hideMessage(String guid) => hideMessages([guid]);

  /// C64: batch variant for multi-select — one cache reload for the whole set.
  Future<void> hideMessages(Iterable<String> guids) async {
    final ids = guids.where((g) => g.isNotEmpty).toSet();
    if (ids.isEmpty) return;
    final keys = _col.ordered
        .where((m) => ids.contains(m.guid))
        .map((m) => '${m.chatGuid ?? chatGuid}\u001f${m.guid}')
        .toSet();
    await app.messagePreferences.setHidden(keys, true);
    if (_disposed) return;
    state = _col.isEmpty ? ThreadState.empty : ThreadState.loaded;
    _notify();
  }

  Future<void> loadOlder() async {
    if (_disposed || loadingOlder || !hasMore || !_historyLoaded) return;
    final api = app.api;
    if (api == null) return;
    loadingOlder = true;
    _notify();
    final baseline = _col.snapshot();
    try {
      final page = await api.getMessageHistory(
        threadGuids,
        limit: _pageSize,
        before: _historyCursor,
      );
      if (_disposed) return;
      await _cacheHistory(page.messages);
      if (_disposed) return;
      _col.mergeServerPage(page.messages, baseline: baseline);
      _historyCursor = page.nextCursor;
      hasMore = page.hasMore;
      error = null;
    } on ApiException catch (e) {
      if (!_disposed) error = _humanize(e);
    } finally {
      loadingOlder = false;
      _notify();
    }
  }

  Future<void> send(String text) async {
    final trimmed = text.trim();
    final api = app.api;
    if (trimmed.isEmpty || api == null) return;

    final tempId = 'tmp-${DateTime.now().microsecondsSinceEpoch}';
    final optimistic = MessageModel.optimistic(
      tempId: tempId,
      text: trimmed,
      dateCreated: DateTime.now().millisecondsSinceEpoch,
    ).copyWith(chatGuid: chatGuid);
    _col.addPending(optimistic);
    await app.cache.addPending(chatGuid, optimistic);
    state = ThreadState.loaded;
    _notify();

    try {
      final confirmed = await api.sendText(
        chatGuid: chatGuid,
        tempGuid: tempId,
        message: trimmed,
      );
      _col.confirmPending(tempId, confirmed);
      await app.cache.confirmPending(chatGuid, tempId, confirmed);
    } on ApiException catch (e) {
      _col.setPendingState(tempId, e.sendState);
      await app.cache.setPendingState(tempId, e.sendState);
      _scheduleReload();
    }
    _notify();
  }

  Future<void> retry(String tempId) async {
    await load(showSpinner: false);
    if (_disposed || _col.pendingByTempId(tempId) == null) return;
    // C63: failed attachment sends retry with their staged bytes.
    final staged = _pendingAttachmentSends[tempId];
    if (staged != null) {
      if (attachmentSending) return;
      _col.removePending(tempId);
      _cleanupAttachmentSend(tempId);
      await app.cache.deletePending(tempId);
      _notify();
      await sendAttachments([staged]);
      return;
    }
    final removed = _col.removePending(tempId);
    final text = removed?.text;
    if (text == null) return;
    await app.cache.deletePending(tempId);
    _notify();
    await send(text);
  }

  Future<void> deletePending(String tempId) async {
    final removed = _col.removePending(tempId);
    if (removed == null) return;
    _cleanupAttachmentSend(tempId);
    await app.cache.deletePending(tempId);
    state = _col.isEmpty ? ThreadState.empty : ThreadState.loaded;
    _notify();
  }

  void markRetractedLocally(String guid, {int? dateRetracted}) {
    if (guid.isEmpty) return;
    final applied = _col.applyUnsend(
      guid,
      dateRetracted ?? DateTime.now().millisecondsSinceEpoch,
    );
    if (!applied) return;
    state = ThreadState.loaded;
    _notify();
  }

  // C63 attachment send: each staged file gets an optimistic bubble that
  // renders the local bytes immediately (pinned in the media cache under
  // `local-<tempId>`), with a live upload progress bar; failures mark the
  // bubble failed (tap to retry) instead of only a snackbar. The server can't
  // echo `tempGuid` for attachments (202 optimistic, no send:match), so the
  // pending row reconciles against the confirmed server row by file identity
  // (see shouldReconcileLocalWithServer / attachmentSendMatches).
  bool attachmentSending = false;
  String? attachmentError;

  /// Staged bytes for in-flight/failed attachment sends, kept for retry and
  /// released after the server row reconciles.
  final Map<String, StagedAttachment> _pendingAttachmentSends = {};
  final Map<String, ValueNotifier<double>> _uploadProgress = {};

  /// Upload progress (0..1) for a pending attachment send, or null.
  ValueNotifier<double>? uploadProgressOf(String tempId) =>
      _uploadProgress[tempId];

  /// C21c: BlueBubbles-style multi-select, conservative send path — each staged
  /// attachment is sent as its own request. The grouped AppleScript send path is
  /// fragile on some Messages setups, so the UI may stage several files while
  /// the transport stays one-file-at-a-time. One catch-up after the sequence
  /// pulls the real rows (they also arrive via message:new).
  Future<void> sendAttachments(List<StagedAttachment> items) async {
    final api = app.api;
    if (api == null || attachmentSending || items.isEmpty) return;
    attachmentSending = true;
    attachmentError = null;
    _notify();

    // C71: stage EVERY bubble up front — a multi-file batch shows all its
    // pending bubbles (with progress rings) immediately. Uploads still run
    // one at a time below; previously the next bubble only appeared after
    // the previous upload finished, so "only the first image showed".
    final queue =
        <({String tempId, StagedAttachment item, MessageModel optimistic})>[];
    final baseMs = DateTime.now().millisecondsSinceEpoch;
    final baseMicro = DateTime.now().microsecondsSinceEpoch;
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      // Index suffix keeps ids unique and preserves the staged order.
      final tempId = 'tmp-att-${baseMicro + i}';
      final optimistic = MessageModel.optimisticAttachment(
        tempId: tempId,
        filename: item.filename,
        totalBytes: item.size,
        dateCreated: baseMs + i,
      ).copyWith(chatGuid: chatGuid);
      _pendingAttachmentSends[tempId] = item;
      _uploadProgress[tempId] = ValueNotifier<double>(0);
      // C66: *pin* the local bytes (non-evictable, synchronous) so the bubble
      // renders instantly — a pending guid must never fall into the
      // spinner/network path. Unpinned in _cleanupAttachmentSend.
      MediaCache.instance.registerLocal(
        MessageModel.localAttachmentGuid(tempId),
        preview: item.thumbnail,
        loadPreview: item.previewBytes,
        loadOriginal: item.readBytes,
      );
      final aspect = item.previewAspectRatio;
      if (aspect != null) {
        MediaCache.instance.rememberAspectRatio(
          MessageModel.localAttachmentGuid(tempId),
          aspect,
        );
      }
      _col.addPending(optimistic);
      queue.add((tempId: tempId, item: item, optimistic: optimistic));
    }
    state = ThreadState.loaded;
    _notify();

    var anySent = false;
    for (final staged in queue) {
      final tempId = staged.tempId;
      final item = staged.item;
      final optimistic = staged.optimistic;
      // The user may have deleted this pending while it was queued.
      if (_col.pendingByTempId(tempId) == null) continue;
      final progress = _uploadProgress[tempId];

      try {
        final sentFilename = await api.sendAttachment(
          chatGuid: chatGuid,
          tempGuid: tempId,
          bytes: item.bytes,
          filePath: item.path,
          filename: item.filename,
          isAudioMessage: item.isAudioMessage,
          onSendProgress: (sent, total) {
            if (!_disposed &&
                identical(_uploadProgress[tempId], progress) &&
                total > 0) {
              progress?.value = sent / total;
            }
          },
        );
        anySent = true;
        // Upload done; the row is now "sent, awaiting the server row". If the
        // server renamed the file (voice conversion), match on the new name.
        var updated = optimistic.copyWith(
          localState: LocalSendState.sentUnconfirmed,
        );
        if (sentFilename != null &&
            sentFilename.isNotEmpty &&
            sentFilename != item.filename) {
          updated = updated.copyWith(
            attachments: [
              for (final a in updated.attachments)
                AttachmentModel(
                  guid: a.guid,
                  downloadUrl: a.downloadUrl,
                  filename: sentFilename,
                  transferName: sentFilename,
                  totalBytes: a.totalBytes,
                  attachmentKind: a.attachmentKind,
                  displayKind: a.displayKind,
                  isPreviewableImage: a.isPreviewableImage,
                ),
            ],
          );
        }
        _col.replacePending(tempId, updated);
        _notify();
      } on ApiException catch (e) {
        if (_col.pendingByTempId(tempId) != null) {
          attachmentError = e.sendState == LocalSendState.failed
              ? e.friendly
              : null;
          _col.setPendingState(tempId, e.sendState);
        }
        _scheduleReload();
        _notify();
      } catch (e) {
        attachmentError = '$e';
        _col.setPendingState(tempId, LocalSendState.failed);
        _notify();
      }
    }

    attachmentSending = false;
    _notify();
    if (anySent) {
      // One catch-up after the sequence; the rows also arrive via message:new.
      await app.catchUp(reason: 'attachment_sent', minInterval: Duration.zero);
    }
  }

  /// C70: confirmed images are server-authoritative. Reconciliation lives
  /// solely in MessageCollection; this sweep just releases staged bytes,
  /// progress notifiers, and pinned local bytes once a pending row is gone.
  /// Failed pendings keep their row (and bytes) for retry.
  void _sweepAttachmentSendBookkeeping() {
    if (_pendingAttachmentSends.isEmpty) return;
    for (final tempId in _pendingAttachmentSends.keys.toList()) {
      if (_col.pendingByTempId(tempId) == null) {
        _cleanupAttachmentSend(tempId);
      }
    }
  }

  void _cleanupAttachmentSend(String tempId) {
    _pendingAttachmentSends.remove(tempId);
    _uploadProgress.remove(tempId)?.dispose();
    MediaCache.instance.unpinLocal(MessageModel.localAttachmentGuid(tempId));
  }

  void clearAttachmentError() {
    if (attachmentError == null) return;
    attachmentError = null;
    _notify();
  }

  void _onWsEvent(WsEvent e) {
    switch (e.type) {
      case 'send:match':
        final tempId = e.data['tempGuid'] as String?;
        final msg = e.data['message'];
        if (tempId != null &&
            msg is Map<String, dynamic> &&
            _col.pendingByTempId(tempId) != null) {
          final confirmed = MessageModel.fromJson(msg);
          if (confirmed.chatGuid != null &&
              !threadGuids.contains(confirmed.chatGuid)) {
            break;
          }
          _col.confirmPending(tempId, confirmed);
          _sweepAttachmentSendBookkeeping();
          unawaited(
            app.cache.confirmPending(
              confirmed.chatGuid ?? chatGuid,
              tempId,
              confirmed,
            ),
          );
          unawaited(app.markRealtimeEventApplied(e));
          _notify();
        }
        break;
      case 'send:error':
        final tempId = e.data['tempGuid'] as String?;
        final code = e.data['code'] as String?;
        final recoverable =
            e.data['recoverable'] == true ||
            e.data['state'] == 'sent_unconfirmed' ||
            code == 'send_confirmation_timeout';
        if (tempId != null && _col.pendingByTempId(tempId) != null) {
          _col.setPendingState(
            tempId,
            recoverable
                ? LocalSendState.sentUnconfirmed
                : LocalSendState.failed,
          );
          unawaited(
            app.cache.setPendingState(
              tempId,
              recoverable
                  ? LocalSendState.sentUnconfirmed
                  : LocalSendState.failed,
            ),
          );
          _notify();
        }
        break;
      case 'message:new':
      case 'message:update':
        final msg = rt.messageFromWsEvent(e);
        if (msg == null || msg.chatGuid == null) {
          unawaited(
            app.recordRealtimeFallback(
              missingChatGuid: msg != null && msg.chatGuid == null,
              malformed: msg == null,
            ),
          );
          _scheduleReload();
          break;
        }
        if (threadGuids.contains(msg.chatGuid)) {
          _col.upsertServer(msg);
          _sweepAttachmentSendBookkeeping();
          unawaited(
            app.cache
                .upsertMessage(msg.chatGuid ?? chatGuid, msg)
                .then(
                  (_) => app.markRealtimeEventApplied(e),
                  onError: (_) => app.recordRealtimeFallback(),
                ),
          );
          state = ThreadState.loaded;
          _notify();
        }
        break;
      case 'message:unsend':
        final eventChat = rt.chatGuidFromWsEvent(e);
        if (eventChat == null) {
          unawaited(app.recordRealtimeFallback(missingChatGuid: true));
          _scheduleReload();
          break;
        }
        if (threadGuids.contains(eventChat)) {
          final guid = e.data['guid'] as String?;
          final dateRetracted = _asInt(e.data['dateRetracted']);
          if (guid == null || !_col.applyUnsend(guid, dateRetracted)) {
            unawaited(app.recordRealtimeFallback(malformed: guid == null));
            _scheduleReload();
          } else {
            unawaited(
              app.cache
                  .applyUnsend(eventChat, guid, dateRetracted)
                  .then((_) => app.markRealtimeEventApplied(e)),
            );
            _notify();
          }
        }
        break;
      default:
        break;
    }
  }

  void _scheduleReload() {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 400), () {
      load(showSpinner: false);
    });
  }

  String _humanize(ApiException e) {
    switch (e.code) {
      case 'unauthorized':
        return MicaLocalizations.current.t('error.tokenRejected');
      case 'timeout':
        return MicaLocalizations.current.t('error.timeoutMessages');
      case 'network_error':
        return MicaLocalizations.current.t('error.unreachable');
      case 'not_found':
        return MicaLocalizations.current.t('error.chatNotFound');
      default:
        return e.message;
    }
  }

  @override
  void dispose() {
    app.messagePreferences.removeListener(_onMessageVisibilityChanged);
    _disposed = true;
    _reloadDebounce?.cancel();
    _wsSub?.cancel();
    _deltaSub?.cancel();
    for (final n in _uploadProgress.values) {
      n.dispose();
    }
    _uploadProgress.clear();
    for (final tempId in _pendingAttachmentSends.keys) {
      MediaCache.instance.unpinLocal(MessageModel.localAttachmentGuid(tempId));
    }
    _pendingAttachmentSends.clear();
    super.dispose();
  }
}

int? _asInt(Object? v) => v is num ? v.toInt() : null;
