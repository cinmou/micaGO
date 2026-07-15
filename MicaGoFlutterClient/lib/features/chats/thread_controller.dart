import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/app_controller.dart';
import '../../core/network/api_client.dart';
import '../../core/network/websocket_client.dart';
import '../../core/storage/media_cache.dart';
import 'attachment_panel.dart' show StagedAttachment;
import 'models/message_model.dart';
import 'realtime_event_helpers.dart' as rt;
import 'store/message_collection.dart';
// Re-export the reconciliation predicate so existing callers/tests that import
// it from thread_controller continue to work after the store extraction.
export 'store/message_collection.dart' show shouldReconcileLocalWithServer;

enum ThreadState { loading, loaded, empty, error }

/// Drives one chat thread. Holds a [MessageCollection] (the per-chat store) and
/// *patches* it from REST pages + WebSocket events — it never reloads the whole
/// thread on an event when the payload is complete. Optimistic sends live in the
/// store and reconcile against later server rows.
class ThreadController extends ChangeNotifier {
  final AppController app;
  final String chatGuid;

  ThreadController({required this.app, required this.chatGuid});

  static const int _pageSize = 50;

  ThreadState state = ThreadState.loading;
  String? error;

  final MessageCollection _col = MessageCollection();

  int _offset = 0;
  bool hasMore = true;
  bool loadingOlder = false;

  StreamSubscription<WsEvent>? _wsSub;
  StreamSubscription<MessageModel>? _deltaSub;
  Timer? _reloadDebounce;

  /// Chronological (oldest → newest); the thread view renders it reversed.
  List<MessageModel> get messages => _col.ordered;

  /// C65: whether [guid] is the confirmed server row of an optimistic send
  /// this session — its bubble already animated in as the pending row, so the
  /// entrance animation must not run again on the swap.
  bool wasReconciledFromPending(String guid) =>
      _col.wasReconciledFromPending(guid);

  void start() {
    _wsSub = app.ws.events.listen(_onWsEvent);
    // C21: also patch from the delta catch-up (the correctness path), not only
    // WebSocket events. GUID dedup in the collection prevents duplicate bubbles.
    _deltaSub = app.deltaMessages.listen(_onDeltaMessage);
    unawaited(app.catchUp(reason: 'thread:$chatGuid'));
    load();
  }

  void _onDeltaMessage(MessageModel msg) {
    if (msg.chatGuid != chatGuid || msg.guid.isEmpty) return;
    if (!_absorbConfirmedAttachmentSend(msg)) _col.upsertServer(msg);
    state = ThreadState.loaded;
    notifyListeners();
  }

  Future<void> load({bool showSpinner = true}) async {
    final api = app.api;
    if (api == null) {
      final cached = await app.cache.listMessages(chatGuid, limit: _pageSize);
      if (cached.isNotEmpty) {
        _col.replaceServerPage(cached);
        state = ThreadState.loaded;
        error = null;
      } else {
        state = ThreadState.error;
        error = 'Not connected.';
      }
      notifyListeners();
      return;
    }
    if (showSpinner) {
      final cached = await app.cache.listMessages(chatGuid, limit: _pageSize);
      if (cached.isNotEmpty) {
        _col.replaceServerPage(cached);
        state = ThreadState.loaded;
      } else {
        state = ThreadState.loading;
      }
      error = null;
      notifyListeners();
    }
    try {
      final fetched = await api.getMessages(
        chatGuid,
        limit: _pageSize,
        offset: 0,
      );
      await app.cache.replaceServerPage(chatGuid, fetched);
      if (_pendingAttachmentSends.isNotEmpty) {
        for (final m in fetched) {
          _absorbConfirmedAttachmentSend(m);
        }
      }
      // Store everything (so unhide can restore it) but never display a
      // client-hidden message.
      final hidden = await app.cache.hiddenMessageGuids();
      _col.replaceServerPage(
        fetched.where((m) => !hidden.contains(m.guid)).toList(),
      );
      _offset = fetched.length;
      hasMore = fetched.length >= _pageSize;
      state = _col.isEmpty ? ThreadState.empty : ThreadState.loaded;
      error = null;
    } on ApiException catch (e) {
      final cached = await app.cache.listMessages(chatGuid, limit: _pageSize);
      if (cached.isNotEmpty) {
        _col.replaceServerPage(cached);
        state = ThreadState.loaded;
        error = null;
      } else {
        state = ThreadState.error;
        error = _humanize(e);
      }
    }
    notifyListeners();
  }

  /// Hides a single message on the client only (the server copy is untouched).
  /// Re-reads the visible page from the cache so it disappears immediately.
  Future<void> hideMessage(String guid) => hideMessages([guid]);

  /// C64: batch variant for multi-select — one cache reload for the whole set.
  Future<void> hideMessages(Iterable<String> guids) async {
    final ids = guids.where((g) => g.isNotEmpty).toSet();
    if (ids.isEmpty) return;
    for (final guid in ids) {
      await app.cache.setMessageHidden(guid, true);
    }
    final cached = await app.cache.listMessages(chatGuid, limit: _pageSize);
    _col.replaceServerPage(cached);
    notifyListeners();
  }

  Future<void> loadOlder() async {
    if (loadingOlder || !hasMore) return;
    final api = app.api;
    if (api == null) return;
    loadingOlder = true;
    notifyListeners();
    try {
      final fetched = await api.getMessages(
        chatGuid,
        limit: _pageSize,
        offset: _offset,
      );
      for (final m in fetched) {
        await app.cache.upsertMessage(chatGuid, m);
      }
      final hidden = await app.cache.hiddenMessageGuids();
      _col.mergeOlder(fetched.where((m) => !hidden.contains(m.guid)).toList());
      _offset += fetched.length;
      hasMore = fetched.length >= _pageSize;
    } on ApiException {
      // Keep what we have; a transient failure shouldn't break the thread.
    }
    loadingOlder = false;
    notifyListeners();
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
    );
    _col.addPending(optimistic);
    await app.cache.addPending(chatGuid, optimistic);
    state = ThreadState.loaded;
    notifyListeners();

    try {
      final confirmed = await api.sendText(
        chatGuid: chatGuid,
        tempGuid: tempId,
        message: trimmed,
      );
      _col.confirmPending(tempId, confirmed);
      await app.cache.confirmPending(chatGuid, tempId, confirmed);
    } on ApiException catch (e) {
      // AppleScript succeeded but DB confirmation timed out → sentUnconfirmed,
      // NOT failed; a later server row / update will upgrade it.
      _col.setPendingState(
        tempId,
        e.code == 'send_confirmation_timeout'
            ? LocalSendState.sentUnconfirmed
            : LocalSendState.failed,
      );
      await app.cache.setPendingState(
        tempId,
        e.code == 'send_confirmation_timeout'
            ? LocalSendState.sentUnconfirmed
            : LocalSendState.failed,
      );
    }
    notifyListeners();
  }

  Future<void> retry(String tempId) async {
    // C63: failed attachment sends retry with their staged bytes.
    final staged = _pendingAttachmentSends[tempId];
    if (staged != null) {
      _col.removePending(tempId);
      _cleanupAttachmentSend(tempId);
      notifyListeners();
      await sendAttachments([staged]);
      return;
    }
    final removed = _col.removePending(tempId);
    final text = removed?.text;
    if (text == null) return;
    notifyListeners();
    await send(text);
  }

  Future<void> deletePending(String tempId) async {
    final removed = _col.removePending(tempId);
    if (removed == null) return;
    _cleanupAttachmentSend(tempId);
    await app.cache.deletePending(tempId);
    state = _col.isEmpty ? ThreadState.empty : ThreadState.loaded;
    notifyListeners();
  }

  void markRetractedLocally(String guid, {int? dateRetracted}) {
    if (guid.isEmpty) return;
    final applied = _col.applyUnsend(
      guid,
      dateRetracted ?? DateTime.now().millisecondsSinceEpoch,
    );
    if (!applied) return;
    state = ThreadState.loaded;
    notifyListeners();
  }

  // C63 attachment send: each staged file gets an optimistic bubble that
  // renders the local bytes immediately (seeded into the media cache under
  // `local-<tempId>`), with a live upload progress bar; failures mark the
  // bubble failed (tap to retry) instead of only a snackbar. The server can't
  // echo `tempGuid` for attachments (202 optimistic, no send:match), so the
  // pending row reconciles against the confirmed server row by file identity
  // (see shouldReconcileLocalWithServer / attachmentSendMatches).
  bool attachmentSending = false;
  String? attachmentError;

  /// Staged bytes for in-flight/failed attachment sends, kept for retry and
  /// for seeding the media cache when the confirmed server row arrives.
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
    notifyListeners();

    var anySent = false;
    for (final item in items) {
      final tempId = 'tmp-att-${DateTime.now().microsecondsSinceEpoch}';
      final optimistic = MessageModel.optimisticAttachment(
        tempId: tempId,
        filename: item.filename,
        totalBytes: item.bytes.length,
        dateCreated: DateTime.now().millisecondsSinceEpoch,
      );
      _pendingAttachmentSends[tempId] = item;
      final progress = ValueNotifier<double>(0);
      _uploadProgress[tempId] = progress;
      // C66: *pin* the local bytes (non-evictable, synchronous) so the bubble
      // renders instantly — a pending guid must never fall into the
      // spinner/network path. Unpinned in _cleanupAttachmentSend.
      MediaCache.instance.pinLocal(
        MessageModel.localAttachmentGuid(tempId),
        item.bytes,
      );
      _col.addPending(optimistic);
      state = ThreadState.loaded;
      notifyListeners();

      try {
        final sentFilename = await api.sendAttachment(
          chatGuid: chatGuid,
          tempGuid: tempId,
          bytes: item.bytes,
          filename: item.filename,
          isAudioMessage: item.isAudioMessage,
          onSendProgress: (sent, total) {
            if (total > 0) progress.value = sent / total;
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
        notifyListeners();
      } on ApiException catch (e) {
        attachmentError = e.friendly;
        _col.setPendingState(tempId, LocalSendState.failed);
        notifyListeners();
        break; // Conservative: stop the sequence on the first failure.
      } catch (e) {
        attachmentError = '$e';
        _col.setPendingState(tempId, LocalSendState.failed);
        notifyListeners();
        break;
      }
    }

    attachmentSending = false;
    notifyListeners();
    if (anySent) {
      // One catch-up after the sequence; the rows also arrive via message:new.
      await app.catchUp(reason: 'attachment_sent', minInterval: Duration.zero);
    }
  }

  /// When a confirmed outgoing server row matches a pending attachment send,
  /// seed the media cache for the *server* attachment keys with the local
  /// bytes (so the just-sent photo is never downloaded back) and drop the
  /// staged bookkeeping. The pending bubble itself is reconciled away inside
  /// the collection.
  bool _absorbConfirmedAttachmentSend(MessageModel server) {
    if (_pendingAttachmentSends.isEmpty ||
        !server.isFromMe ||
        server.attachments.isEmpty) {
      return false;
    }
    final pending = _pendingAttachmentSends.keys
        .map(_col.pendingByTempId)
        .whereType<MessageModel>();
    final tempId = matchingPendingTempId(pending, server);
    if (tempId == null) return false;
    final item = _pendingAttachmentSends[tempId];
    if (item == null) return false;

    final lowerName = item.filename.toLowerCase();
    for (final a in server.attachments) {
      final sameFile =
          server.attachments.length == 1 ||
          a.displayName.toLowerCase() == lowerName ||
          (item.bytes.isNotEmpty && a.totalBytes == item.bytes.length);
      if (!sameFile) continue;
      // The inline renderer reads `previewUrl ?? guid`. Seed that exact key
      // before the pending row is replaced, so a confirmed local photo does
      // not enter a second loading presentation.
      if (a.canRenderInlineImage) {
        unawaited(MediaCache.instance.seed(a.previewUrl ?? a.guid, item.bytes));
      }
      unawaited(
        MediaCache.instance.seed(MediaCache.fullMediaKey(a.guid), item.bytes),
      );
    }
    // One atomic visual transition: replace this pending row with the server
    // row before releasing its pinned bytes and progress notifier.
    _col.confirmPending(tempId, server);
    _cleanupAttachmentSend(tempId);
    return true;
  }

  void _cleanupAttachmentSend(String tempId) {
    _pendingAttachmentSends.remove(tempId);
    _uploadProgress.remove(tempId)?.dispose();
    MediaCache.instance.unpinLocal(MessageModel.localAttachmentGuid(tempId));
  }

  void clearAttachmentError() {
    if (attachmentError == null) return;
    attachmentError = null;
    notifyListeners();
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
          _col.confirmPending(tempId, confirmed);
          unawaited(app.cache.confirmPending(chatGuid, tempId, confirmed));
          unawaited(app.markRealtimeEventApplied(e));
          notifyListeners();
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
          notifyListeners();
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
        if (msg.chatGuid == chatGuid) {
          if (rt.isReactionMessage(msg)) {
            final target = rt.reactionTargetGuid(msg);
            final applied =
                target != null &&
                _col.applyReactionEvent(
                  targetGuid: target,
                  reaction: ReactionModel(
                    type: rt.reactionType(msg),
                    fromHandle: msg.handleId,
                    isFromMe: msg.isFromMe,
                    eventGuid: msg.guid,
                    createdAt: msg.dateCreated,
                  ),
                  add: rt.isReactionAdd(msg),
                );
            unawaited(
              app.cache.applyReactionEvent(chatGuid, msg).then((ok) {
                if (ok) return app.markRealtimeEventApplied(e);
                return app.recordRealtimeFallback();
              }),
            );
            if (!applied) _scheduleReload();
          } else {
            if (!_absorbConfirmedAttachmentSend(msg)) {
              _col.upsertServer(msg);
            }
            unawaited(
              app.cache
                  .upsertMessage(chatGuid, msg)
                  .then(
                    (_) => app.markRealtimeEventApplied(e),
                    onError: (_) => app.recordRealtimeFallback(),
                  ),
            );
          }
          state = ThreadState.loaded;
          notifyListeners();
        }
        break;
      case 'message:unsend':
        final eventChat = rt.chatGuidFromWsEvent(e);
        if (eventChat == null) {
          unawaited(app.recordRealtimeFallback(missingChatGuid: true));
          _scheduleReload();
          break;
        }
        if (eventChat == chatGuid) {
          final guid = e.data['guid'] as String?;
          final dateRetracted = _asInt(e.data['dateRetracted']);
          if (guid == null || !_col.applyUnsend(guid, dateRetracted)) {
            unawaited(app.recordRealtimeFallback(malformed: guid == null));
            _scheduleReload();
          } else {
            unawaited(
              app.cache
                  .applyUnsend(chatGuid, guid, dateRetracted)
                  .then((_) => app.markRealtimeEventApplied(e)),
            );
            notifyListeners();
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
        return 'Token rejected (401). Re-pair with the server.';
      case 'timeout':
        return 'Timed out loading messages.';
      case 'network_error':
        return 'Could not reach the server.';
      case 'not_found':
        return 'This chat was not found on the server.';
      default:
        return e.message;
    }
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    _wsSub?.cancel();
    _deltaSub?.cancel();
    for (final n in _uploadProgress.values) {
      n.dispose();
    }
    _uploadProgress.clear();
    super.dispose();
  }
}

MessageModel? messageFromWsEvent(WsEvent e) => rt.messageFromWsEvent(e);

String? chatGuidFromWsEvent(WsEvent e) => rt.chatGuidFromWsEvent(e);

int? _asInt(Object? v) => v is num ? v.toInt() : null;
