import '../chat_service.dart';
import '../../../core/l10n/app_localizations.dart';

/// A chat row for the chat list.
///
/// The MicaGo server's `Chat` object (v0.9 contract) currently exposes only
/// `guid, chatIdentifier, serviceName, displayName, isArchived`. The extra
/// fields below (last message, unread, participants, pinned/muted, group) are
/// **optional** and parsed only if a future server adds them — the UI falls back
/// gracefully when they are absent. This keeps the model ready for richer
/// iMessage features without breaking on today's responses.
class ChatSummary {
  final String guid;
  final String? chatIdentifier;
  final String? serviceName; // raw chat.db value, e.g. iMessage | SMS | null
  final String? serviceCategory; // server-normalized: imessage|sms|rcs|unknown
  final String? effectiveService; // C21 server-authoritative, message-aware
  // C21c: explicit server-computed send capabilities. The client consumes these
  // directly — it never re-derives sendability from the service + setting. Null
  // (older server) falls back to deriving from [service] + the SMS setting.
  final bool? canSendTextRaw;
  final bool? canSendAttachmentsRaw;
  final String? displayName; // group name; null for 1:1 (per server contract)
  final bool isArchived;

  // --- optional / future fields (null/empty when the server omits them) ---
  final String? lastMessagePreview;
  final int? lastMessageAt; // Unix epoch ms
  final int? unreadCount;
  // C43: the watermark-derived unread dot. `hasUnread` is the source of truth
  // for showing the dot (set by the cache from latestRenderableAt vs the local
  // read watermark); `latestFromMe` whether the newest message is outgoing.
  final bool hasUnread;
  final bool latestFromMe;
  final List<String> participants;
  final bool? isGroupRaw; // explicit flag if the server provides one
  final bool isPinned;
  final bool isMuted;

  // --- C7 renderable-timeline summary (server-computed) ---
  final bool hasRenderableMessages;
  final bool unsupportedOnly;
  final String hiddenReason; // "" | "debug_only" | "empty"

  const ChatSummary({
    required this.guid,
    this.chatIdentifier,
    this.serviceName,
    this.serviceCategory,
    this.effectiveService,
    this.canSendTextRaw,
    this.canSendAttachmentsRaw,
    this.displayName,
    this.isArchived = false,
    this.lastMessagePreview,
    this.lastMessageAt,
    this.unreadCount,
    this.hasUnread = false,
    this.latestFromMe = false,
    this.participants = const [],
    this.isGroupRaw,
    this.isPinned = false,
    this.isMuted = false,
    this.hasRenderableMessages = true,
    this.unsupportedOnly = false,
    this.hiddenReason = '',
  });

  /// The single server-authoritative service (C21): the server's message-aware
  /// `effectiveService` (prefers iMessage), with serviceCategory/serviceName as
  /// a fallback for older servers. Drives the badge, composer, and every send
  /// path. Never inferred from the GUID, handle, or phone-number shape.
  ChatService get service => chatServiceFromServer(
    effectiveService: effectiveService,
    category: serviceCategory,
    rawService: serviceName,
  );

  /// C21c: whether text can be sent to this chat. Uses the explicit server
  /// capability when present (zero client inference); falls back to deriving
  /// from [service] + [allowSmsSend] only for an older server. iMessage always;
  /// SMS iff the setting is on; unknown never.
  bool canSendText({required bool allowSmsSend}) =>
      canSendTextRaw ?? service.canSendWith(allowSmsSend: allowSmsSend);

  /// C21c: whether attachments can be sent to this chat (same source as text).
  bool canSendAttachments({required bool allowSmsSend}) =>
      canSendAttachmentsRaw ?? service.canSendWith(allowSmsSend: allowSmsSend);

  /// Best display title: group/display name, else the handle/identifier, else
  /// the opaque GUID as a last resort.
  String get title {
    final dn = displayName?.trim() ?? '';
    if (dn.isNotEmpty) return dn;
    if (isGroup) {
      final generated = _groupTitle(participants);
      return generated.isNotEmpty
          ? generated
          : MicaLocalizations.current.t('chat.groupChat');
    }
    final id = chatIdentifier?.trim() ?? '';
    if (id.isNotEmpty) return id;
    return guid;
  }

  String displayTitle({String? Function(String?)? resolveName}) {
    if (!isGroup) {
      final resolved = resolveName?.call(chatIdentifier)?.trim() ?? '';
      return resolved.isNotEmpty ? resolved : title;
    }
    final dn = displayName?.trim() ?? '';
    if (dn.isNotEmpty) return dn;
    final names = participants
        .map((h) {
          final resolved = resolveName?.call(h)?.trim() ?? '';
          return resolved.isNotEmpty ? resolved : h.trim();
        })
        .where((h) => h.isNotEmpty)
        .toList(growable: false);
    final generated = _groupTitle(names);
    return generated.isNotEmpty
        ? generated
        : MicaLocalizations.current.t('chat.groupChat');
  }

  static String _groupTitle(List<String> handles) {
    final names = handles
        .map(_groupTitlePart)
        .where((h) => h.isNotEmpty)
        .toList(growable: false);
    if (names.isEmpty) return '';
    if (names.length == 1) return names.first;
    if (names.length <= 4) {
      final head = names.take(names.length - 1).join(', ');
      return '$head & ${names.last}';
    }
    return '${names.take(3).join(', ')} & ${names.length - 3} others';
  }

  static String _groupTitlePart(String raw) {
    final cleaned = raw.replaceAll('\uFFFC', ' ').trim();
    if (cleaned.isEmpty) return '';
    final parts = cleaned.split(RegExp(r'\s+'));
    return parts.first;
  }

  /// Heuristic group detection: trust the server when it provides `isGroup`;
  /// otherwise fall back to BlueBubbles-style signals. `;+;` is the legacy
  /// Messages chat GUID marker for groups and covers older MicaGo servers that
  /// did not expose participant/style metadata yet.
  bool get isGroup {
    if (isGroupRaw != null) return isGroupRaw!;
    if (guid.contains(';+;')) return true;
    if ((displayName?.trim() ?? '').isNotEmpty) return true;
    return participants.length > 1;
  }

  /// 1–2 character avatar initials derived from the title.
  String get initials {
    final source = title.trim();
    if (source.isEmpty) return '#';
    // Phone numbers / handles: use a generic glyph rather than digits.
    if (RegExp(r'^[+\d][\d\s()\-]*$').hasMatch(source)) return '#';
    final words = source
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '#';
    if (words.length == 1) return _firstLetter(words.first);
    return _firstLetter(words[0]) + _firstLetter(words[1]);
  }

  static String _firstLetter(String word) {
    if (word.isEmpty) return '';
    return String.fromCharCode(word.runes.first).toUpperCase();
  }

  ChatSummary copyWith({
    String? guid,
    String? chatIdentifier,
    String? serviceName,
    String? serviceCategory,
    String? effectiveService,
    bool? canSendTextRaw,
    bool? canSendAttachmentsRaw,
    String? displayName,
    bool? isArchived,
    String? lastMessagePreview,
    int? lastMessageAt,
    int? unreadCount,
    bool? hasUnread,
    bool? latestFromMe,
    List<String>? participants,
    bool? isGroupRaw,
    bool? isPinned,
    bool? isMuted,
    bool? hasRenderableMessages,
    bool? unsupportedOnly,
    String? hiddenReason,
  }) {
    return ChatSummary(
      guid: guid ?? this.guid,
      chatIdentifier: chatIdentifier ?? this.chatIdentifier,
      serviceName: serviceName ?? this.serviceName,
      serviceCategory: serviceCategory ?? this.serviceCategory,
      effectiveService: effectiveService ?? this.effectiveService,
      canSendTextRaw: canSendTextRaw ?? this.canSendTextRaw,
      canSendAttachmentsRaw:
          canSendAttachmentsRaw ?? this.canSendAttachmentsRaw,
      displayName: displayName ?? this.displayName,
      isArchived: isArchived ?? this.isArchived,
      lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      unreadCount: unreadCount ?? this.unreadCount,
      hasUnread: hasUnread ?? this.hasUnread,
      latestFromMe: latestFromMe ?? this.latestFromMe,
      participants: participants ?? this.participants,
      isGroupRaw: isGroupRaw ?? this.isGroupRaw,
      isPinned: isPinned ?? this.isPinned,
      isMuted: isMuted ?? this.isMuted,
      hasRenderableMessages:
          hasRenderableMessages ?? this.hasRenderableMessages,
      unsupportedOnly: unsupportedOnly ?? this.unsupportedOnly,
      hiddenReason: hiddenReason ?? this.hiddenReason,
    );
  }

  factory ChatSummary.fromJson(Map<String, dynamic> json) {
    int? asInt(Object? v) => v is num ? v.toInt() : null;
    return ChatSummary(
      guid: (json['guid'] as String?) ?? '',
      chatIdentifier: json['chatIdentifier'] as String?,
      serviceName: json['serviceName'] as String?,
      serviceCategory: json['serviceCategory'] as String?,
      effectiveService: json['effectiveService'] as String?,
      canSendTextRaw: json['canSendText'] as bool?,
      canSendAttachmentsRaw: json['canSendAttachments'] as bool?,
      displayName: json['displayName'] as String?,
      isArchived: (json['isArchived'] as bool?) ?? false,
      // Prefer the C7 server-computed renderable preview/timestamp (real data).
      lastMessagePreview:
          json['latestRenderablePreview'] as String? ??
          json['lastMessagePreview'] as String? ??
          json['lastMessage'] as String?,
      lastMessageAt:
          asInt(json['latestRenderableAt']) ??
          asInt(json['lastMessageAt']) ??
          asInt(json['lastMessageDate']),
      unreadCount: asInt(json['unreadCount']),
      // hasUnread is cache-derived (not a server field); latestRenderableFromMe
      // comes from the server (C43).
      hasUnread: (json['hasUnread'] as bool?) ?? false,
      latestFromMe: (json['latestRenderableFromMe'] as bool?) ?? false,
      participants:
          (json['participants'] as List?)?.whereType<String>().toList(
            growable: false,
          ) ??
          const [],
      isGroupRaw: json['isGroup'] as bool?,
      isPinned: (json['isPinned'] as bool?) ?? false,
      isMuted: (json['isMuted'] as bool?) ?? false,
      hasRenderableMessages: (json['hasRenderableMessages'] as bool?) ?? true,
      unsupportedOnly: (json['unsupportedOnly'] as bool?) ?? false,
      hiddenReason: (json['hiddenReason'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'guid': guid,
    'chatIdentifier': chatIdentifier,
    'serviceName': serviceName,
    'serviceCategory': serviceCategory,
    'effectiveService': effectiveService,
    'canSendText': canSendTextRaw,
    'canSendAttachments': canSendAttachmentsRaw,
    'displayName': displayName,
    'isArchived': isArchived,
    'latestRenderablePreview': lastMessagePreview,
    'latestRenderableAt': lastMessageAt,
    'unreadCount': unreadCount,
    'latestRenderableFromMe': latestFromMe,
    'participants': participants,
    'isGroup': isGroupRaw,
    'isPinned': isPinned,
    'isMuted': isMuted,
    'hasRenderableMessages': hasRenderableMessages,
    'unsupportedOnly': unsupportedOnly,
    'hiddenReason': hiddenReason,
  };
}
