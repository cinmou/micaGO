import '../chat_service.dart';
import 'chat_summary.dart';

/// A contact-level conversation that groups one or more real server chats
/// ("routes") for the same person — e.g. iMessage-via-phone, iMessage-via-email,
/// and SMS-via-phone (C21). This is a **client-side view only**: the server chat
/// rows and their real GUIDs are never merged or mutated, and every send still
/// goes to a specific route's real `chat.guid`.
class MergedChat {
  /// The grouping key — a contact id when resolved, else the single chat's guid.
  final String key;

  /// The real server chats that belong to this contact, in preference order
  /// (see [mergeChatsByContact]). Never empty.
  final List<ChatSummary> routes;

  const MergedChat({required this.key, required this.routes});

  bool get isMerged => routes.length > 1;

  /// The default route to open/send on: prefer iMessage, then the most recent
  /// sendable route, with SMS/unknown last. (Last-used persistence is a future
  /// refinement; v1 uses preference + recency.)
  ChatSummary get primary => routes.first;

  /// Display title comes from the primary route's title (contact name/handle).
  String get title => primary.title;

  /// Stable local-preference key for per-contact/per-group UI customizations.
  /// Merged 1:1 routes share one key; group chats are standalone.
  String get localCustomizationKey => key;

  int get unreadCount => routes
      .where((route) => route.hasUnread)
      .fold<int>(0, (sum, route) => sum + (route.unreadCount ?? 0));

  /// C43: the dot is derived (watermark-based) — any route reading as unread
  /// makes the merged contact unread, independent of the auxiliary count.
  bool get hasUnread => routes.any((r) => r.hasUnread);

  /// Newest last-message timestamp across all routes (for list ordering).
  int? get lastMessageAt {
    int? best;
    for (final r in routes) {
      final t = r.lastMessageAt;
      if (t != null && (best == null || t > best)) best = t;
    }
    return best;
  }

  /// Preview from the route with the newest message.
  String? get lastMessagePreview {
    ChatSummary? newest;
    for (final r in routes) {
      if (r.lastMessageAt == null) continue;
      if (newest == null ||
          (r.lastMessageAt ?? 0) > (newest.lastMessageAt ?? 0)) {
        newest = r;
      }
    }
    return (newest ?? primary).lastMessagePreview;
  }
}

/// Groups 1:1 chats that resolve to the same contact into one [MergedChat].
/// Safety rules (the task's "prefer safety over over-merging"):
/// - Group chats are never merged (always standalone).
/// - A chat is only merged when its handle resolves to a contact id AND at least
///   one other chat resolves to the same id. Unresolved handles stay standalone.
/// - Never decided from the chat GUID shape, only from the contact resolution +
///   the server-provided service on each route.
///
/// [contactIdFor] maps a handle (chatIdentifier) to a stable contact id, or null
/// when there's no confident match (inject `ContactsService.contactIdFor`).
List<MergedChat> mergeChatsByContact(
  List<ChatSummary> chats,
  String? Function(String? handle) contactIdFor,
) {
  // Bucket by contact id; unresolved/group chats get a unique standalone key.
  final groups = <String, List<ChatSummary>>{};
  final order = <String>[]; // preserve first-seen order for stability
  for (final chat in chats) {
    String key;
    if (chat.isGroup) {
      key = 'group:${chat.guid}';
    } else {
      final id = contactIdFor(chat.chatIdentifier);
      key = (id != null && id.isNotEmpty) ? 'contact:$id' : 'chat:${chat.guid}';
    }
    if (!groups.containsKey(key)) {
      groups[key] = [];
      order.add(key);
    }
    groups[key]!.add(chat);
  }

  return [
    for (final key in order)
      MergedChat(key: key, routes: _sortRoutes(groups[key]!)),
  ];
}

/// Orders a contact's routes: iMessage first, then other sendable routes by
/// recency, with SMS/unknown last. The first element is the default send route.
List<ChatSummary> _sortRoutes(List<ChatSummary> routes) {
  int rank(ChatSummary c) {
    switch (c.service) {
      case ChatService.imessage:
        return 0;
      case ChatService.rcs:
        return 1;
      case ChatService.sms:
        return 2; // SMS last unless the user explicitly picks it
      case ChatService.unknown:
        return 3;
    }
  }

  final sorted = [...routes];
  sorted.sort((a, b) {
    final byRank = rank(a).compareTo(rank(b));
    if (byRank != 0) return byRank;
    // Same service → most recently used first.
    return (b.lastMessageAt ?? 0).compareTo(a.lastMessageAt ?? 0);
  });
  return sorted;
}
