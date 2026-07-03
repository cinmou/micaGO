import 'dart:convert';

import '../storage/secure_store.dart';

/// C32 — a tiny persisted per-chat buffer of recent message previews, used to
/// drive Android MessagingStyle notifications. It must be reachable from BOTH
/// the FCM background isolate (a fresh process per push) and the keep-alive main
/// isolate. It is bounded and small; cleared when a chat is opened.
const String _notifBufferKey = 'micago.notif_buffer.v1';

/// Keep only the last few previews per chat (a MessagingStyle notification only
/// shows a handful of lines).
const int _maxPerChat = 6;

/// One buffered message preview. Short keys keep the stored JSON compact.
class BufferedNotifMessage {
  final String guid;
  final String sender;
  final String senderKey;
  final String text;
  final int ts;
  const BufferedNotifMessage({
    required this.guid,
    required this.sender,
    required this.senderKey,
    required this.text,
    required this.ts,
  });

  Map<String, dynamic> toJson() => {
    'g': guid,
    's': sender,
    'sk': senderKey,
    't': text,
    'ts': ts,
  };

  factory BufferedNotifMessage.fromJson(Map<String, dynamic> j) =>
      BufferedNotifMessage(
        guid: j['g'] as String? ?? '',
        sender: j['s'] as String? ?? '',
        senderKey: j['sk'] as String? ?? j['s'] as String? ?? '',
        text: j['t'] as String? ?? '',
        ts: (j['ts'] as num?)?.toInt() ?? 0,
      );
}

final SecureStore _storage = SecureStore();

Future<Map<String, List<BufferedNotifMessage>>> _readAll() async {
  try {
    final raw = await _storage.readValue(_notifBufferKey);
    if (raw == null || raw.isEmpty) return {};
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return decoded.map(
      (k, v) => MapEntry(
        k,
        (v as List)
            .map(
              (e) => BufferedNotifMessage.fromJson(e as Map<String, dynamic>),
            )
            .toList(),
      ),
    );
  } catch (_) {
    return {};
  }
}

Future<void> _writeAll(Map<String, List<BufferedNotifMessage>> map) async {
  try {
    final encoded = jsonEncode(
      map.map((k, v) => MapEntry(k, v.map((e) => e.toJson()).toList())),
    );
    await _storage.writeValue(_notifBufferKey, encoded);
  } catch (_) {
    // Best-effort; a failure just means the next notification won't stack.
  }
}

/// Appends [msg] to [chatGuid]'s buffer and returns the chat's current list
/// (oldest→newest, capped). Dedupes by message guid, so a message delivered by
/// BOTH FCM and keep-alive is buffered once (no duplicate line, no duplicate
/// notification once both use the same per-chat notification id).
Future<List<BufferedNotifMessage>> appendChatNotification(
  String chatGuid,
  BufferedNotifMessage msg,
) async {
  final all = await _readAll();
  final list = all[chatGuid] ?? <BufferedNotifMessage>[];
  if (msg.guid.isNotEmpty && list.any((m) => m.guid == msg.guid)) {
    return list; // already buffered for this chat
  }
  list.add(msg);
  while (list.length > _maxPerChat) {
    list.removeAt(0);
  }
  all[chatGuid] = list;
  await _writeAll(all);
  return list;
}

/// Drops a chat's buffer (called when the user opens that chat).
Future<void> clearChatNotificationBuffer(String chatGuid) async {
  final all = await _readAll();
  if (all.remove(chatGuid) != null) await _writeAll(all);
}
