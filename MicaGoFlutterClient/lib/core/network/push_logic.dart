/// C22 — pure push decision rules, kept free of any Firebase import so they can
/// be unit-tested and reasoned about in isolation. [PushService] composes these.
library;

/// BlueBubbles dedup rule: a foreground FCM message only needs a catch-up when
/// the realtime socket is NOT connected — if the socket is live it already
/// delivered the event, so the push is ignored (no duplicate work/bubbles).
bool pushShouldCatchUp({required bool realtimeConnected}) => !realtimeConnected;

/// The chat GUID a push routes to (notification tap → open this chat), or null.
String? pushChatGuid(Map<String, dynamic> data) {
  final guid = data['chatGuid'];
  return (guid is String && guid.isNotEmpty) ? guid : null;
}

/// Whether a push has anything worth showing as a local notification. Test
/// pushes and preview-disabled (empty title+body) pushes are skipped so we don't
/// raise an empty/noisy notification.
bool pushShouldNotify(Map<String, dynamic> data) {
  if ((data['type'] ?? '') == 'test') return false;
  final title = (data['title'] as String?)?.trim() ?? '';
  final body = (data['body'] as String?)?.trim() ?? '';
  return title.isNotEmpty || body.isNotEmpty;
}

/// C30: the title to show — the sender/chat name when present, else a generic
/// fallback so a preview-disabled push still reads sensibly.
String notificationTitle(Map<String, dynamic> data) {
  final title = (data['title'] as String?)?.trim() ?? '';
  return title.isNotEmpty ? title : 'New message';
}

/// C30: the body to show — the message preview, or null when preview is off
/// (the title alone, e.g. just the sender, is enough).
String? notificationBody(Map<String, dynamic> data) {
  final body = (data['body'] as String?)?.trim() ?? '';
  return body.isEmpty ? null : body;
}

int? notificationTimestampMs(Map<String, dynamic> data) {
  final value = data['createdAt'];
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

bool notificationIsGroup(Map<String, dynamic> data) {
  final value = data['isGroup'];
  if (value is bool) return value;
  if (value is String) return value.toLowerCase() == 'true';
  final guid = (data['chatGuid'] as String?)?.trim() ?? '';
  return guid.contains(';+;');
}

String notificationSenderName(Map<String, dynamic> data) {
  return messageNotificationTitle(
    serverTitle: data['senderName'] as String? ?? data['title'] as String?,
    handle: data['handle'] as String?,
  );
}

String notificationConversationTitle(Map<String, dynamic> data) {
  final explicit = (data['conversationTitle'] as String?)?.trim() ?? '';
  if (explicit.isNotEmpty) return explicit;
  if (notificationIsGroup(data)) {
    final title = (data['title'] as String?)?.trim() ?? '';
    if (title.isNotEmpty && !_genericNotificationTitles.contains(title)) {
      return title;
    }
    return 'Group chat';
  }
  return notificationSenderName(data);
}

/// C30: validates a direct-reply text from the notification's inline input.
/// Returns the trimmed text, or null when there's nothing to send.
String? cleanReplyText(String? input) {
  final text = input?.trim() ?? '';
  return text.isEmpty ? null : text;
}

/// Generic server/placeholder titles that should be overridden by a real
/// sender name or handle when one is available.
const Set<String> _genericNotificationTitles = {'New message', 'New iMessage'};

/// C31: the title to display for a message notification — "who it's from".
/// Priority: an on-device contact name (resolved in the main isolate), then the
/// server-provided sender/title when it isn't a generic placeholder, then the
/// raw handle (phone/email), then a generic fallback. It never returns a chat
/// GUID or an empty string, so a notification always reads sensibly.
String messageNotificationTitle({
  String? contactName,
  String? serverTitle,
  String? handle,
}) {
  final name = contactName?.trim() ?? '';
  if (name.isNotEmpty) return name;
  final title = serverTitle?.trim() ?? '';
  if (title.isNotEmpty && !_genericNotificationTitles.contains(title)) {
    return title;
  }
  final h = handle?.trim() ?? '';
  if (h.isNotEmpty) return h;
  return title.isNotEmpty ? title : 'New message';
}

/// C31: the body for a locally-built (keep-alive) notification, honoring the
/// server's notification preview mode so the local path matches the FCM path:
/// `sender_and_text` shows the text; `sender`/`none` show no preview text.
String? localNotificationBody(String? text, String previewMode) {
  if (previewMode != 'sender_and_text') return null;
  final t = text?.trim() ?? '';
  return t.isEmpty ? null : t;
}
