/// Pure, testable message **display preferences** and the thread-row transform
/// that applies them (Part I). These are display-only: they never delete or
/// mutate server data, and never hide a failed outgoing message.
library;

import 'message_render.dart';
import 'models/message_model.dart';

/// How much outgoing delivery state to show.
enum DeliveryLabelMode { off, compact, detailed }

/// Local, persisted message-display preferences.
class MessageDisplayPrefs {
  final bool hideUnsupportedRows; // hide kind==unknown rows
  final bool mergeConsecutiveSystem; // collapse runs of system rows
  final bool mergeTapbacks; // attach tapbacks to their target bubble
  final bool showEffectHints; // show "Sent with …" labels
  final DeliveryLabelMode deliveryLabels;
  final bool showDebugChats; // include debug-only/noise-only chats in the list

  const MessageDisplayPrefs({
    this.hideUnsupportedRows = false,
    this.mergeConsecutiveSystem = true,
    this.mergeTapbacks = true,
    this.showEffectHints = true,
    this.deliveryLabels = DeliveryLabelMode.compact,
    this.showDebugChats = false,
  });

  static const defaults = MessageDisplayPrefs();

  MessageDisplayPrefs copyWith({
    bool? hideUnsupportedRows,
    bool? mergeConsecutiveSystem,
    bool? mergeTapbacks,
    bool? showEffectHints,
    DeliveryLabelMode? deliveryLabels,
    bool? showDebugChats,
  }) {
    return MessageDisplayPrefs(
      hideUnsupportedRows: hideUnsupportedRows ?? this.hideUnsupportedRows,
      mergeConsecutiveSystem:
          mergeConsecutiveSystem ?? this.mergeConsecutiveSystem,
      mergeTapbacks: mergeTapbacks ?? this.mergeTapbacks,
      showEffectHints: showEffectHints ?? this.showEffectHints,
      deliveryLabels: deliveryLabels ?? this.deliveryLabels,
      showDebugChats: showDebugChats ?? this.showDebugChats,
    );
  }

  Map<String, String> toMap() => {
    'hideUnsupportedRows': hideUnsupportedRows ? '1' : '0',
    'mergeConsecutiveSystem': mergeConsecutiveSystem ? '1' : '0',
    'mergeTapbacks': mergeTapbacks ? '1' : '0',
    'showEffectHints': showEffectHints ? '1' : '0',
    'deliveryLabels': deliveryLabels.name,
    'showDebugChats': showDebugChats ? '1' : '0',
  };

  factory MessageDisplayPrefs.fromMap(Map<String, String?> m) {
    bool b(String k, bool d) => m[k] == null ? d : m[k] == '1';
    DeliveryLabelMode dl = DeliveryLabelMode.values.firstWhere(
      (e) => e.name == m['deliveryLabels'],
      orElse: () => DeliveryLabelMode.compact,
    );
    return MessageDisplayPrefs(
      hideUnsupportedRows: b('hideUnsupportedRows', false),
      mergeConsecutiveSystem: b('mergeConsecutiveSystem', true),
      mergeTapbacks: b('mergeTapbacks', true),
      showEffectHints: b('showEffectHints', true),
      deliveryLabels: dl,
      showDebugChats: b('showDebugChats', false),
    );
  }
}

/// One rendered row after display preferences are applied.
class DisplayRow {
  final MessageModel message; // the primary message of the row
  final MessageRenderableKind kind;

  /// Tapbacks merged onto this (message) row, when [MessageDisplayPrefs.mergeTapbacks].
  final List<MessageModel> reactions;

  /// Sticker associated-message rows merged onto this target row.
  final List<MessageModel> stickers;

  /// Number of system messages collapsed into this row (1 = not merged).
  final int mergedSystemCount;

  /// The collapsed system messages (for debug inspection of merged rows).
  final List<MessageModel> mergedMessages;

  const DisplayRow({
    required this.message,
    required this.kind,
    this.reactions = const [],
    this.stickers = const [],
    this.mergedSystemCount = 1,
    this.mergedMessages = const [],
  });

  bool get isMergedSystem => mergedSystemCount > 1;
}

bool _isSystemKind(MessageRenderableKind k) =>
    k == MessageRenderableKind.service ||
    k == MessageRenderableKind.retracted ||
    k == MessageRenderableKind.reaction ||
    k == MessageRenderableKind.unknown;

/// Applies display preferences to a chronological message list, producing the
/// rows to render. Never hides a failed outgoing message; reaction rows can be
/// merged onto their target; consecutive system rows can be collapsed.
List<DisplayRow> buildDisplayRows(
  List<MessageModel> messages,
  MessageDisplayPrefs prefs,
) {
  // 1) If merging tapbacks, map target guid → reactions and mark them consumed.
  final reactionsByTarget = <String, List<MessageModel>>{};
  final stickersByTarget = <String, List<MessageModel>>{};
  final consumed = <String>{};
  final guids = {for (final m in messages) m.guid};
  for (final m in messages) {
    if (isKeptAudioNotice(m)) {
      consumed.add(m.dedupeKey);
      continue;
    }
    if (isInteractiveUpdate(m)) {
      consumed.add(m.dedupeKey);
      continue;
    }
    if (isAssociatedSticker(m)) {
      final target = reactionTargetGuid(m.associatedMessageGuid);
      if (target != null && guids.contains(target)) {
        stickersByTarget.putIfAbsent(target, () => []).add(m);
        consumed.add(m.dedupeKey);
      }
      continue;
    }
    if (prefs.mergeTapbacks) {
      if (renderableKindFor(m) != MessageRenderableKind.reaction) continue;
      final target = reactionTargetGuid(m.associatedMessageGuid);
      if (target != null && guids.contains(target)) {
        reactionsByTarget.putIfAbsent(target, () => []).add(m);
        consumed.add(m.dedupeKey);
      }
    }
  }

  final rows = <DisplayRow>[];
  for (final m in messages) {
    if (consumed.contains(m.dedupeKey)) continue;
    final kind = renderableKindFor(m);
    final failed = deliveryStateFor(m) == MessageDeliveryState.failed;

    // Never hide a failed outgoing message.
    if (prefs.hideUnsupportedRows &&
        kind == MessageRenderableKind.unknown &&
        !failed) {
      continue;
    }

    if (_isSystemKind(kind) && !failed) {
      // Merge consecutive system rows when enabled.
      if (prefs.mergeConsecutiveSystem &&
          rows.isNotEmpty &&
          _isSystemKind(rows.last.kind)) {
        final prev = rows.removeLast();
        rows.add(
          DisplayRow(
            message: m, // most-recent system message is the row's anchor
            kind: kind,
            mergedSystemCount: prev.mergedSystemCount + 1,
            mergedMessages: [...prev.mergedMessages, prev.message, m],
          ),
        );
        continue;
      }
      rows.add(DisplayRow(message: m, kind: kind));
      continue;
    }

    rows.add(
      DisplayRow(
        message: m,
        kind: kind,
        reactions: reactionsByTarget[m.guid] ?? const [],
        stickers: stickersByTarget[m.guid] ?? const [],
      ),
    );
  }
  return rows;
}
