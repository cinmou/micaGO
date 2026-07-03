import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/app_controller.dart';
import '../../core/network/api_client.dart';
import '../../core/network/websocket_client.dart';
import 'models/chat_summary.dart';
import 'models/message_model.dart';
import 'realtime_event_helpers.dart' as rt;

enum ChatListState { idle, loading, loaded, empty, error }

/// Loads and holds the chat list from `GET /api/chats`.
class ChatListController extends ChangeNotifier {
  final AppController app;

  ChatListController(this.app);

  ChatListState state = ChatListState.idle;
  List<ChatSummary> chats = const [];
  String? error;
  StreamSubscription<WsEvent>? _wsSub;
  StreamSubscription<MessageModel>? _deltaSub;
  StreamSubscription<void>? _reloadSub;
  StreamSubscription<void>? _seenSub;
  Timer? _reloadDebounce;

  /// When true, also request debug-only/noise-only chats from the server.
  bool includeDebug = false;

  bool get isLoading => state == ChatListState.loading;

  void startRealtime() {
    _wsSub ??= app.ws.events.listen(_onWsEvent);
    // Delta catch-up is already applied to the cache by AppController. The chat
    // list only needs a lightweight cache refresh here; doing another upsert per
    // message doubles DB work and hurts scrolling/resume performance.
    _deltaSub ??= app.deltaMessages.listen(
      (_) => unawaited(_reloadFromCache()),
    );
    // The test contact toggling on/off adds/removes a chat off-band.
    _reloadSub ??= app.chatListReloads.listen((_) => _scheduleServerReload());
    // The open thread advanced a read watermark (C47) — re-derive the dot from
    // the cache so it clears immediately, even on the tablet two-pane layout
    // where the list stays visible beside the thread.
    _seenSub ??= app.chatSeen.listen((_) => unawaited(_reloadFromCache()));
    unawaited(app.catchUp(reason: 'chat-list'));
  }

  /// Updates the debug-chats preference and reloads if it changed.
  void setIncludeDebug(bool value) {
    if (includeDebug == value) return;
    includeDebug = value;
    unawaited(load(showSpinner: false));
  }

  /// Loads the chat list. [showSpinner] controls whether to flip into the
  /// loading state (false for a silent pull-to-refresh).
  Future<void> load({bool showSpinner = true}) async {
    final api = app.api;
    if (api == null) {
      final cached = await app.cache.listChats(includeDebug: includeDebug);
      chats = cached;
      state = cached.isEmpty ? ChatListState.error : ChatListState.loaded;
      error = cached.isEmpty ? 'Not connected to a server.' : null;
      notifyListeners();
      return;
    }

    if (showSpinner) {
      final cached = await app.cache.listChats(includeDebug: includeDebug);
      if (cached.isNotEmpty) {
        chats = cached;
        state = ChatListState.loaded;
      } else {
        state = ChatListState.loading;
      }
      error = null;
      notifyListeners();
    }

    try {
      final result = await api.getChats(debug: includeDebug);
      await app.cache.upsertChats(result);
      // C54: apply any restored pin/hide flags to chats as they sync in.
      await app.cache.applyPendingChatFlags();
      // Display from the cache, restricted to the chats the server still returns.
      // The cache derives the unread dot (watermark) and pin order, so a full
      // reload, delta, resume, or pull-to-refresh all yield the same correct
      // unread state — independent of FCM / WS / notifications (C43).
      final live = {for (final c in result) c.guid};
      final cached = await app.cache.listChats(includeDebug: includeDebug);
      chats = cached.where((c) => live.contains(c.guid)).toList();
      state = chats.isEmpty ? ChatListState.empty : ChatListState.loaded;
      error = null;
    } on ApiException catch (e) {
      final cached = await app.cache.listChats(includeDebug: includeDebug);
      if (cached.isNotEmpty) {
        chats = cached;
        state = ChatListState.loaded;
        error = null;
      } else {
        state = ChatListState.error;
        error = _humanize(e);
      }
    }
    notifyListeners();
  }

  /// C42: hide every route of a (possibly merged) contact, then reload once.
  Future<void> hideChats(Iterable<String> guids) async {
    for (final guid in guids) {
      await app.cache.setChatHidden(guid, true);
    }
    chats = await app.cache.listChats(includeDebug: includeDebug);
    notifyListeners();
  }

  /// C42: pin/unpin every route of a contact so the merged card sorts to the top.
  Future<void> setPinned(Iterable<String> guids, bool pinned) async {
    for (final guid in guids) {
      await app.cache.setChatPinned(guid, pinned);
    }
    chats = await app.cache.listChats(includeDebug: includeDebug);
    notifyListeners();
  }

  String _humanize(ApiException e) {
    switch (e.code) {
      case 'unauthorized':
        return 'Token rejected (401). Re-pair with the server.';
      case 'timeout':
        return 'Timed out loading chats.';
      case 'network_error':
        return 'Could not reach the server.';
      default:
        return e.message;
    }
  }

  void _onWsEvent(WsEvent e) {
    switch (e.type) {
      case 'message:new':
      case 'message:update':
        unawaited(_patchMessageEvent(e));
        break;
      case 'message:unsend':
        unawaited(_patchUnsendEvent(e));
        break;
      default:
        break;
    }
  }

  Future<void> _patchMessageEvent(WsEvent e) async {
    final msg = rt.messageFromWsEvent(e);
    final chatGuid = msg?.chatGuid;
    if (msg == null || chatGuid == null || chatGuid.isEmpty) {
      await app.recordRealtimeFallback(
        missingChatGuid: msg != null,
        malformed: msg == null,
        chatListReload: true,
      );
      _scheduleServerReload();
      return;
    }
    try {
      if (rt.isReactionMessage(msg)) {
        final ok = await app.cache.applyReactionEvent(chatGuid, msg);
        if (!ok) {
          await app.recordRealtimeFallback(chatListReload: true);
          _scheduleServerReload();
          return;
        }
        await app.markRealtimeEventApplied(e);
        return;
      }
      final known = await _patchMessage(msg);
      if (!known) return;
      await app.markRealtimeEventApplied(e, localDbWrites: 2);
    } catch (_) {
      await app.recordRealtimeFallback(chatListReload: true);
      _scheduleServerReload();
    }
  }

  Future<bool> _patchMessage(MessageModel msg) async {
    final chatGuid = msg.chatGuid;
    if (chatGuid == null || chatGuid.isEmpty) {
      return false;
    }
    try {
      // Only a genuinely new message bumps the unread count, so a replayed or
      // duplicate event (WS reconnect, FCM catch-up, resume) can never over-count.
      // Checked before upsert; otherwise every message would look known.
      final isNew =
          msg.guid.isEmpty || !await app.cache.hasMessageGuid(msg.guid);
      await app.cache.upsertMessage(chatGuid, msg);
      // C47: ingestion only lights (or leaves) the dot; it never advances the
      // read watermark for someone else's message. The open thread owns marking
      // a chat read (markChatsViewed), so an arriving message can no longer
      // wrongly clear a dot via a stale "active chat". My own messages are seen.
      final seen = msg.isFromMe;
      final known = await app.cache.bumpChatWithMessage(
        msg,
        markUnread: isNew && !seen,
        seen: seen,
      );
      if (!known) {
        await app.recordRealtimeFallback(chatListReload: true);
        _scheduleServerReload();
        return false;
      }
      chats = await app.cache.listChats(includeDebug: includeDebug);
      state = chats.isEmpty ? ChatListState.empty : ChatListState.loaded;
      error = null;
      notifyListeners();
      return true;
    } catch (_) {
      await app.recordRealtimeFallback(chatListReload: true);
      _scheduleServerReload();
      return false;
    }
  }

  Future<void> _reloadFromCache() async {
    chats = await app.cache.listChats(includeDebug: includeDebug);
    state = chats.isEmpty ? ChatListState.empty : ChatListState.loaded;
    error = null;
    notifyListeners();
  }

  Future<void> _patchUnsendEvent(WsEvent e) async {
    final chatGuid = rt.chatGuidFromWsEvent(e);
    final guid = e.data['guid'] as String?;
    if (chatGuid == null || guid == null) {
      await app.recordRealtimeFallback(
        missingChatGuid: chatGuid == null,
        malformed: guid == null,
        chatListReload: true,
      );
      _scheduleServerReload();
      return;
    }
    try {
      await app.cache.applyUnsend(
        chatGuid,
        guid,
        _asInt(e.data['dateRetracted']),
      );
      chats = await app.cache.listChats(includeDebug: includeDebug);
      await app.markRealtimeEventApplied(e);
      notifyListeners();
    } catch (_) {
      await app.recordRealtimeFallback(chatListReload: true);
      _scheduleServerReload();
    }
  }

  void _scheduleServerReload() {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 150), () {
      load(showSpinner: false);
    });
  }

  int? _asInt(Object? value) => value is num ? value.toInt() : null;

  Future<void> markRoutesRead(Iterable<String> guids) async {
    await app.cache.markChatsSeen(guids);
    chats = await app.cache.listChats(includeDebug: includeDebug);
    state = chats.isEmpty ? ChatListState.empty : ChatListState.loaded;
    notifyListeners();
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    _wsSub?.cancel();
    _deltaSub?.cancel();
    _reloadSub?.cancel();
    _seenSub?.cancel();
    super.dispose();
  }
}
