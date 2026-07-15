/// Pure, testable per-chat message store (C7).
///
/// This is the single source of truth for one thread's messages. REST pages and
/// WebSocket events are *patched* into the keyed maps — never a full reload —
/// mirroring BlueBubbles' in-memory `ChatMessages` struct. It has no Flutter or
/// async dependencies so every event/reconciliation case is unit-testable.
///
/// - Confirmed/server messages are keyed by `guid`.
/// - Optimistic outgoing messages are keyed by `tempId` until reconciled.
/// - Dedupe is by guid (server) and tempId (pending); a pending row is removed
///   when a matching server row arrives (see [shouldReconcileLocalWithServer]).
library;

import '../models/message_model.dart';

class MessageCollection {
  final Map<String, MessageModel> _server = {}; // by guid
  final Map<String, MessageModel> _pending = {}; // by tempId

  /// C65: server guids that replaced an optimistic pending row. The thread's
  /// entrance animation consults this so the confirmed row of a send doesn't
  /// animate in a second time (the optimistic bubble already did).
  final Set<String> _reconciledServerGuids = {};
  bool wasReconciledFromPending(String guid) =>
      _reconciledServerGuids.contains(guid);

  /// Cached, sorted display list; rebuilt lazily after mutations.
  List<MessageModel>? _orderedCache;

  bool get isEmpty => _server.isEmpty && _pending.isEmpty;
  int get length => _server.length + _pending.length;

  /// Chronological (oldest → newest) display list: confirmed server messages
  /// followed by not-yet-reconciled optimistic sends, stably ordered by
  /// dateCreated then identity.
  List<MessageModel> get ordered {
    return _orderedCache ??= _buildOrdered();
  }

  List<MessageModel> _buildOrdered() {
    final all = <MessageModel>[..._server.values, ..._pending.values];
    all.sort((a, b) {
      final byDate = (a.dateCreated ?? 0).compareTo(b.dateCreated ?? 0);
      if (byDate != 0) return byDate;
      // Pending after server at the same instant; otherwise stable by key.
      final ap = a.tempId != null && a.guid.isEmpty ? 1 : 0;
      final bp = b.tempId != null && b.guid.isEmpty ? 1 : 0;
      if (ap != bp) return ap - bp;
      return a.dedupeKey.compareTo(b.dedupeKey);
    });
    return List.unmodifiable(all);
  }

  void _invalidate() => _orderedCache = null;

  MessageModel? serverByGuid(String guid) => _server[guid];
  MessageModel? pendingByTempId(String tempId) => _pending[tempId];

  void clear() {
    _server.clear();
    _pending.clear();
    _invalidate();
  }

  /// Replaces the confirmed set with a freshly fetched page (newest-first or
  /// any order; we key by guid). Pending sends are kept and reconciled.
  void replaceServerPage(Iterable<MessageModel> page) {
    _server.clear();
    for (final m in page) {
      if (m.guid.isNotEmpty) {
        _server[m.guid] = m;
      } else if (m.tempId != null) {
        _pending[m.tempId!] = m;
      }
    }
    _reconcilePending();
    _invalidate();
  }

  /// Merges an older page (pagination) without dropping existing messages.
  void mergeOlder(Iterable<MessageModel> older) {
    for (final m in older) {
      if (m.guid.isNotEmpty) _server.putIfAbsent(m.guid, () => m);
    }
    _invalidate();
  }

  /// Inserts/merges a single server message (message:new / send confirmation).
  /// Patches in place by guid and reconciles any matching optimistic row.
  void upsertServer(MessageModel m) {
    if (m.guid.isEmpty) return;
    final isNew = !_server.containsKey(m.guid);
    _server[m.guid] = m;
    _reconcileOne(m, isNewRow: isNew);
    _invalidate();
  }

  /// Patches an existing message by guid (message:update: delivered/read/edit).
  /// If the guid isn't present, inserts it (so updates are never lost).
  void applyUpdate(MessageModel m) => upsertServer(m);

  /// Marks an existing message retracted and clears its displayed content.
  /// Returns false when the guid is unknown (caller may schedule a reload).
  bool applyUnsend(String guid, int? dateRetracted) {
    final existing = _server[guid];
    if (existing == null) return false;
    _server[guid] = existing.copyWith(
      text: '',
      attachments: const [],
      isRetracted: true,
      dateRetracted: dateRetracted,
      errorCode: 0,
      localState: LocalSendState.confirmed,
    );
    _invalidate();
    return true;
  }

  bool applyReactionEvent({
    required String targetGuid,
    required ReactionModel reaction,
    required bool add,
  }) {
    final target = _server[targetGuid];
    if (target == null) return false;
    final filtered = target.reactions
        .where(
          (r) =>
              !(r.type == reaction.type &&
                  r.fromHandle == reaction.fromHandle &&
                  r.isFromMe == reaction.isFromMe),
        )
        .toList(growable: true);
    _server[targetGuid] = target.copyWith(
      reactions: add ? [...filtered, reaction] : filtered,
    );
    _invalidate();
    return true;
  }

  // --- Optimistic send lifecycle -------------------------------------------

  void addPending(MessageModel optimistic) {
    final t = optimistic.tempId;
    if (t == null) return;
    _pending[t] = optimistic;
    _invalidate();
  }

  void setPendingState(String tempId, LocalSendState state) {
    final p = _pending[tempId];
    if (p == null) return;
    _pending[tempId] = p.copyWith(localState: state);
    _invalidate();
  }

  /// Replaces a pending row's model in place (e.g. the server renamed the file
  /// during a voice conversion and reconciliation must match the new name).
  void replacePending(String tempId, MessageModel updated) {
    if (_pending[tempId] == null) return;
    _pending[tempId] = updated;
    _invalidate();
  }

  /// Replaces an optimistic row with its confirmed server message.
  void confirmPending(String tempId, MessageModel server) {
    if (_pending.remove(tempId) != null && server.guid.isNotEmpty) {
      _reconciledServerGuids.add(server.guid);
    }
    if (server.guid.isNotEmpty) _server[server.guid] = server;
    _invalidate();
  }

  /// Removes a pending row entirely (e.g. before a retry re-adds it).
  MessageModel? removePending(String tempId) {
    final removed = _pending.remove(tempId);
    _invalidate();
    return removed;
  }

  // --- Reconciliation -------------------------------------------------------

  void _reconcilePending() {
    if (_pending.isEmpty) return;
    final servers = _server.values.toList(growable: false)
      ..sort(_compareMessageTime);
    for (final server in servers) {
      if (_reconciledServerGuids.contains(server.guid)) continue;
      final tempId = matchingPendingTempId(
        _pending.values,
        server,
        allowAttachmentFallback: false,
      );
      if (tempId == null) continue;
      _pending.remove(tempId);
      _reconciledServerGuids.add(server.guid);
    }
  }

  void _reconcileOne(MessageModel server, {bool isNewRow = false}) {
    if (_pending.isEmpty) return;
    final tempId = matchingPendingTempId(
      _pending.values,
      server,
      allowAttachmentFallback: isNewRow,
    );
    if (tempId == null) return;
    _pending.remove(tempId);
    _reconciledServerGuids.add(server.guid);
  }
}

int _compareMessageTime(MessageModel a, MessageModel b) =>
    (a.dateCreated ?? 0).compareTo(b.dateCreated ?? 0);

/// Selects exactly one optimistic row for [server]. Exact identity matches win;
/// a new attachment row may fall back to the closest non-failed attachment send
/// in the confirmation window. This is deliberately one-to-one: a server row
/// must never remove several same-name or same-size pending sends.
String? matchingPendingTempId(
  Iterable<MessageModel> pending,
  MessageModel server, {
  bool allowAttachmentFallback = true,
}) {
  final candidates = pending.where((m) => m.tempId != null).toList();
  if (candidates.isEmpty) return null;

  final exact = candidates
      .where((m) => shouldReconcileLocalWithServer(m, server))
      .toList(growable: false);
  if (exact.isNotEmpty) return _closestPending(exact, server).tempId;

  if (!allowAttachmentFallback ||
      !server.isFromMe ||
      _hasComparableText(server) ||
      server.attachments.isEmpty ||
      server.dateCreated == null) {
    return null;
  }
  final fallback = candidates
      .where((m) {
        final at = m.dateCreated;
        return m.isFromMe &&
            m.hasAttachments &&
            !_hasComparableText(m) &&
            m.localState != LocalSendState.failed &&
            at != null &&
            (at - server.dateCreated!).abs() <=
                const Duration(minutes: 5).inMilliseconds;
      })
      .toList(growable: false);
  // C70: the fallback must be unambiguous. With several sends in flight
  // (multi-image batches land within the same second) "closest by time" is a
  // coin flip — a wrong guess swapped whole bubbles. Identity matching above
  // handles the normal case; conversions reconcile only when exactly one
  // pending could be the source.
  if (fallback.length != 1) return null;
  return fallback.single.tempId;
}

MessageModel _closestPending(
  List<MessageModel> candidates,
  MessageModel server,
) {
  final serverAt = server.dateCreated ?? 0;
  candidates.sort((a, b) {
    final byDistance = ((a.dateCreated ?? 0) - serverAt).abs().compareTo(
      ((b.dateCreated ?? 0) - serverAt).abs(),
    );
    if (byDistance != 0) return byDistance;
    return (a.dateCreated ?? 0).compareTo(b.dateCreated ?? 0);
  });
  return candidates.first;
}

/// True when an optimistic local send should be replaced by a server message —
/// matched by guid, tempId, (chat-scoped) identical text, or attachment file
/// identity (C63 — attachment sends get no `send:match`), each within a time
/// window. Prevents showing both a pending bubble and its confirmed server row.
bool shouldReconcileLocalWithServer(MessageModel local, MessageModel server) {
  if (!local.isFromMe || !server.isFromMe || server.guid.isEmpty) return false;
  if (local.guid.isNotEmpty && local.guid == server.guid) return true;
  if (local.tempId != null && local.tempId == server.tempId) return true;
  final localAt = local.dateCreated;
  final serverAt = server.dateCreated;
  if (localAt == null || serverAt == null) return false;
  final apart = (localAt - serverAt).abs();
  // C63: pending attachment sends (no text) reconcile by file identity; the
  // window is wider than text because the upload + AppleScript send + sync can
  // take a while for large files.
  //
  // C67: "has text" here means *visible* text. chat.db stores attachment
  // messages with the object-replacement character (U+FFFC) in the text
  // column and the server passes it through — treating that as a caption made
  // every photo send fail to reconcile (two bubbles until the thread was
  // reopened, which drops the memory-only pending row).
  if (local.hasAttachments && !_hasComparableText(local)) {
    return apart <= const Duration(minutes: 5).inMilliseconds &&
        !_hasComparableText(server) &&
        attachmentSendMatches(local, server);
  }
  final localText = _normaliseComparableText(local.text);
  final serverText = _normaliseComparableText(server.text);
  if (localText.isEmpty || localText != serverText) return false;
  return apart <= const Duration(minutes: 2).inMilliseconds;
}

/// Visible-text semantics shared by every reconciliation check: strips the
/// attachment placeholder (U+FFFC) and replacement char (U+FFFD) before
/// trimming, so an attachment-only row is recognized as such even though its
/// raw text column is non-empty.
String _normaliseComparableText(String? text) => (text ?? '')
    .replaceAll('\uFFFC', ' ')
    .replaceAll('\uFFFD', ' ')
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ')
    .toLowerCase();

bool _hasComparableText(MessageModel m) =>
    _normaliseComparableText(m.text).isNotEmpty;
