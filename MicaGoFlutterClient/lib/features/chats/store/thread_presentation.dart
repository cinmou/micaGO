/// Precomputed thread view model (C7 Part E).
///
/// All per-row work (classification, sender label, reply preview, reaction
/// merge, effect label, delivery visibility, date separators, body text) is
/// done **once** here — outside the scroll item builder — so the hot
/// `itemBuilder` stays trivial and scrolling is smooth. Pure + testable: the
/// contact resolver is injected, so there is no Flutter/provider dependency.
library;

import '../message_display.dart';
import '../emoji_text.dart';
import '../message_render.dart';
import '../models/message_model.dart';

/// A single rendered thread row: a date separator, a message, or the
/// loading-older spinner. Stable [key] drives ListView element reuse.
sealed class ThreadViewItem {
  String get key;
}

class DateSeparatorItem extends ThreadViewItem {
  final String label;
  DateSeparatorItem(this.label);
  @override
  String get key => 'date:$label';
}

/// C21u: a centered time chip inserted only between **large time gaps** within
/// the same day (BlueBubbles-style), so timestamps appear when useful instead
/// of under every bubble. Keyed by the boundary message so it stays stable.
class TimeSeparatorItem extends ThreadViewItem {
  final String label;
  final String afterKey;
  TimeSeparatorItem(this.label, this.afterKey);
  @override
  String get key => 'time:$afterKey';
}

class LoadingOlderItem extends ThreadViewItem {
  @override
  String get key => 'loading-older';
}

/// A fully-resolved message row. Widgets read these fields directly; they must
/// not re-derive anything in the build path.
class MessageViewItem extends ThreadViewItem {
  final MessageModel message;
  final MessageRenderableKind kind;
  final bool isSystem;

  // Precomputed presentation:
  final String? systemLabel; // for system/unknown/retracted/reaction rows
  final int mergedSystemCount;
  final String? senderLabel; // shown only in groups for incoming; else null
  final bool showSenderName; // first row in an incoming group sender run
  final bool showSenderAvatar; // last row in an incoming group sender run
  final String? body; // sanitized display text (null = none)
  final ReplyPreview? reply;
  final List<MessageModel> reactions;
  final List<MessageModel> stickers;
  final String? effectHint;
  final MessageSendEffect sendEffect;
  final MessageDeliveryState deliveryState;
  final bool showStatus; // whether to render a delivery label
  final bool showTimestamp; // whether the footer shows the time by default
  final bool showBubbleTail; // only the last bubble in a same-side run gets one
  final bool compactWithPrevious; // tight vertical gap inside same-sender run
  final bool compactWithNext; // tight vertical gap inside same-sender run

  MessageViewItem({
    required this.message,
    required this.kind,
    required this.isSystem,
    required this.systemLabel,
    required this.mergedSystemCount,
    required this.senderLabel,
    required this.showSenderName,
    required this.showSenderAvatar,
    required this.body,
    required this.reply,
    required this.reactions,
    required this.stickers,
    required this.effectHint,
    required this.sendEffect,
    required this.deliveryState,
    required this.showStatus,
    required this.showTimestamp,
    required this.showBubbleTail,
    required this.compactWithPrevious,
    required this.compactWithNext,
  });

  @override
  String get key => 'msg:${message.dedupeKey}';
}

/// Resolves a local contact display name for a handle (injected so the builder
/// stays pure/testable).
typedef ContactNameResolver = String? Function(String? handleId);

class ThreadPresentationBuilder {
  /// Builds the chronological (oldest → newest) view-item list. The thread view
  /// renders it reversed. [loadingOlder] appends a spinner item at the top
  /// (i.e. last in chronological order).
  static List<ThreadViewItem> build({
    required List<MessageModel> messages,
    required MessageDisplayPrefs prefs,
    required bool isGroup,
    required ContactNameResolver resolveName,
    bool loadingOlder = false,
    bool use24HourFormat = false,
    String? localeTag,
  }) {
    final rows = buildDisplayRows(messages, prefs);
    final byGuid = {for (final m in messages) m.guid: m};

    // Delivery-label visibility: compact = latest outgoing plus separate
    // read/delivered boundaries, so the footer shows where the recipient read
    // up to instead of collapsing everything onto the bottom-most outgoing row.
    String? lastOutgoingKey;
    String? lastReadOutgoingKey;
    String? lastDeliveredOutgoingKey;
    var lastReadOutgoingIndex = -1;
    var lastDeliveredOutgoingIndex = -1;
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      if (!m.isFromMe) continue;
      lastOutgoingKey = m.dedupeKey;
      final state = deliveryStateFor(m);
      if (state == MessageDeliveryState.read) {
        lastReadOutgoingKey = m.dedupeKey;
        lastReadOutgoingIndex = i;
      } else if (state == MessageDeliveryState.delivered) {
        lastDeliveredOutgoingKey = m.dedupeKey;
        lastDeliveredOutgoingIndex = i;
      }
    }
    if (lastReadOutgoingIndex > lastDeliveredOutgoingIndex) {
      lastDeliveredOutgoingKey = null;
    }
    bool showStatusFor(MessageModel m) {
      switch (prefs.deliveryLabels) {
        case DeliveryLabelMode.off:
          return false;
        case DeliveryLabelMode.compact:
          return m.dedupeKey == lastOutgoingKey ||
              m.dedupeKey == lastReadOutgoingKey ||
              m.dedupeKey == lastDeliveredOutgoingKey;
        case DeliveryLabelMode.detailed:
          return m.isFromMe;
      }
    }

    ReplyPreview? replyFor(MessageModel m) {
      if (!isReply(m)) return null;
      final target = byGuid[m.threadOriginatorGuid];
      if (target == null) {
        return ReplyPreview(
          sender: '',
          text: null,
          targetLoaded: false,
          targetGuid: m.threadOriginatorGuid,
        );
      }
      return ReplyPreview(
        sender: resolveSenderLabel(
          target,
          isGroup: isGroup,
          contactName: resolveName(target.handleId),
        ),
        text: displayText(target),
        targetLoaded: true,
        targetGuid: target.guid,
      );
    }

    // Only outgoing bubbles own footers. The newest outgoing row anchors the
    // default footer time; incoming timestamps stay in separators/reveal UI.
    String? lastOutgoingRowKey;
    for (final row in rows) {
      if (row.message.isFromMe) lastOutgoingRowKey = row.message.dedupeKey;
    }

    final items = <ThreadViewItem>[];
    DateTime? lastDay;
    int? lastTs;
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final m = row.message;
      final ts = m.dateCreated;
      if (ts != null) {
        final dt = DateTime.fromMillisecondsSinceEpoch(ts);
        final day = DateTime(dt.year, dt.month, dt.day);
        if (lastDay == null || day != lastDay) {
          // A day boundary shows the first message's local timestamp: today is
          // just the time, while older days keep their localized day/date label.
          items.add(
            DateSeparatorItem(
              threadTimestampLabel(
                dt,
                now: DateTime.now(),
                use24h: use24HourFormat,
                locale: localeTag ?? 'en',
              ),
            ),
          );
          lastDay = day;
        } else if (shouldShowTimeSeparator(lastTs, ts)) {
          // Same day but a large gap since the previous message: show the same
          // date-aware label style as day boundaries, so older pauses read as
          // "Yesterday 09:30" / "Monday 09:30" instead of a bare clock.
          items.add(
            TimeSeparatorItem(
              threadTimestampLabel(
                dt,
                now: DateTime.now(),
                use24h: use24HourFormat,
                locale: localeTag ?? 'en',
              ),
              m.dedupeKey,
            ),
          );
        }
        lastTs = ts;
      }

      final isSystem = _isSystemKind(row.kind);
      final next = i + 1 < rows.length ? rows[i + 1] : null;
      final prev = i > 0 ? rows[i - 1] : null;
      final nextIsSystem = next == null || _isSystemKind(next.kind);
      final separatedFromNext =
          next != null && _hasRenderedSeparatorBetween(m, next.message);
      final nextIsSmallEmoji =
          next != null && !nextIsSystem && _isSmallEmojiMessage(next.message);
      final compactWithPrevious =
          !isSystem &&
          prev != null &&
          !_hasRenderedSeparatorBetween(prev.message, m) &&
          _sameBubbleRun(prev, row);
      final compactWithNext =
          !isSystem &&
          next != null &&
          !separatedFromNext &&
          _sameBubbleRun(row, next);
      // Any sender-run break gives the previous bubble its pointed lower
      // corner. This covers side/sender changes, the five-minute grouping gap,
      // and rendered date/time separators.
      final showTailWithBreaks =
          !isSystem && (!compactWithNext || nextIsSmallEmoji);
      final inIncomingGroupRun = isGroup && !isSystem && !m.isFromMe;
      final sameAsPrev =
          inIncomingGroupRun && prev != null && _sameSenderRun(prev, row);
      final sameAsNext =
          inIncomingGroupRun && next != null && _sameSenderRun(row, next);
      final senderLabel = inIncomingGroupRun
          ? resolveSenderLabel(
              m,
              isGroup: isGroup,
              contactName: resolveName(m.handleId),
            )
          : null;

      items.add(
        MessageViewItem(
          message: m,
          kind: row.kind,
          isSystem: isSystem,
          systemLabel: isSystem
              ? _systemLabel(row.kind, m, senderName: resolveName(m.handleId))
              : null,
          mergedSystemCount: row.mergedSystemCount,
          senderLabel: senderLabel,
          showSenderName: inIncomingGroupRun && !sameAsPrev,
          showSenderAvatar: inIncomingGroupRun && !sameAsNext,
          body: isSystem ? null : displayText(m),
          reply: isSystem ? null : replyFor(m),
          reactions: row.reactions,
          stickers: row.stickers,
          effectHint: (!isSystem && prefs.showEffectHints)
              ? effectLabel(m.expressiveSendStyleId)
              : null,
          sendEffect: isSystem
              ? MessageSendEffect.none
              : sendEffectFor(m.expressiveSendStyleId),
          deliveryState: deliveryStateFor(m),
          showStatus: !isGroup && !isSystem && showStatusFor(m),
          showTimestamp:
              !isGroup &&
              !isSystem &&
              m.isFromMe &&
              m.dedupeKey == lastOutgoingRowKey,
          showBubbleTail: showTailWithBreaks,
          compactWithPrevious: compactWithPrevious,
          compactWithNext: compactWithNext,
        ),
      );
    }

    if (loadingOlder) items.add(LoadingOlderItem());
    return items;
  }

  static String _systemLabel(
    MessageRenderableKind kind,
    MessageModel m, {
    String? senderName,
  }) {
    switch (kind) {
      case MessageRenderableKind.service:
        return serviceEventLabel(m);
      case MessageRenderableKind.retracted:
        // Covers genuine unsends and the unrecoverable attachment placeholders
        // (missing_attachment_rows / empty_edited_residue) that C26 routes here.
        return retractedLabel(m, senderName: senderName);
      case MessageRenderableKind.reaction:
        final t = tapbackFromCode(m.associatedMessageType);
        if (t == null) return 'Reacted to a message';
        final emoji = tapbackEmoji(t.kind);
        return t.isRemoval
            ? 'Removed a $emoji reaction'
            : '$emoji Reacted to a message';
      default:
        if (m.semanticKind == 'deleted') return 'Message deleted';
        if (m.semanticKind == 'unavailable') return 'Message unavailable';
        return 'Unsupported message';
    }
  }

  static bool _hasRenderedSeparatorBetween(
    MessageModel current,
    MessageModel next,
  ) {
    final currentTs = current.dateCreated;
    final nextTs = next.dateCreated;
    if (currentTs == null || nextTs == null) return false;
    final currentDate = DateTime.fromMillisecondsSinceEpoch(currentTs);
    final nextDate = DateTime.fromMillisecondsSinceEpoch(nextTs);
    final currentDay = DateTime(
      currentDate.year,
      currentDate.month,
      currentDate.day,
    );
    final nextDay = DateTime(nextDate.year, nextDate.month, nextDate.day);
    return currentDay != nextDay || shouldShowTimeSeparator(currentTs, nextTs);
  }

  static bool _isSmallEmojiMessage(MessageModel message) {
    if (message.hasAttachments) return false;
    final text = displayText(message);
    return text != null && isBigEmoji(text);
  }

  static bool _isSystemKind(MessageRenderableKind kind) =>
      kind == MessageRenderableKind.service ||
      kind == MessageRenderableKind.reaction ||
      kind == MessageRenderableKind.retracted ||
      kind == MessageRenderableKind.unknown;

  static bool _sameSenderRun(DisplayRow a, DisplayRow b) {
    if (_isSystemKind(a.kind) || _isSystemKind(b.kind)) return false;
    final am = a.message;
    final bm = b.message;
    if (am.isFromMe || bm.isFromMe) return false;
    final ah = am.handleId?.trim();
    final bh = bm.handleId?.trim();
    if (ah == null || ah.isEmpty || bh == null || bh.isEmpty || ah != bh) {
      return false;
    }
    final at = am.dateCreated;
    final bt = bm.dateCreated;
    if (at != null &&
        bt != null &&
        (bt - at).abs() > kSenderRunGap.inMilliseconds) {
      return false;
    }
    return true;
  }

  static bool _sameBubbleRun(DisplayRow a, DisplayRow b) {
    if (_isSystemKind(a.kind) || _isSystemKind(b.kind)) return false;
    final am = a.message;
    final bm = b.message;
    if (am.isFromMe != bm.isFromMe) return false;
    if (!am.isFromMe) {
      final ah = am.handleId?.trim();
      final bh = bm.handleId?.trim();
      if (ah != bh) return false;
    }
    final at = am.dateCreated;
    final bt = bm.dateCreated;
    if (at != null &&
        bt != null &&
        (bt - at).abs() > kSenderRunGap.inMilliseconds) {
      return false;
    }
    return true;
  }
}

/// C21u: the gap (since the previous message, same day) above which a centered
/// time chip is shown. BlueBubbles groups closely-spaced messages and only
/// surfaces a timestamp when the conversation pauses.
const Duration kTimeClusterGap = Duration(minutes: 60);

/// iMessage-style sender-run grouping for group chats: close consecutive
/// incoming messages from the same sender share one avatar/name group.
const Duration kSenderRunGap = Duration(minutes: 5);

/// Whether a same-day time separator should precede a message sent at [ts],
/// given the previous message's timestamp [prevTs]. Pure + testable.
bool shouldShowTimeSeparator(
  int? prevTs,
  int? ts, {
  Duration gap = kTimeClusterGap,
}) {
  if (prevTs == null || ts == null) return false;
  return (ts - prevTs) >= gap.inMilliseconds;
}
