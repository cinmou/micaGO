import 'dart:convert';

import '../storage/local_cache_store.dart';

/// C32 — a tiny persisted per-chat buffer of recent message previews, used to
/// drive Android MessagingStyle notifications. It must be reachable from BOTH
/// the FCM background isolate (a fresh process per push) and the keep-alive main
/// isolate. It is bounded and small; cleared when a chat is opened.
const String _notifBufferKey = 'notification_previews.v2';

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
  final int? readThrough;
  final String? avatarPath;
  final String? avatarResource;
  const BufferedNotifMessage({
    required this.guid,
    required this.sender,
    required this.senderKey,
    required this.text,
    required this.ts,
    this.readThrough,
    this.avatarPath,
    this.avatarResource,
  });

  Map<String, dynamic> toJson() => {
    'g': guid,
    's': sender,
    'sk': senderKey,
    't': text,
    'ts': ts,
    if (readThrough != null) 'rt': readThrough,
    if (avatarPath != null) 'a': avatarPath,
    if (avatarResource != null) 'ar': avatarResource,
  };

  factory BufferedNotifMessage.fromJson(Map<String, dynamic> j) =>
      BufferedNotifMessage(
        guid: j['g'] as String? ?? '',
        sender: j['s'] as String? ?? '',
        senderKey: j['sk'] as String? ?? j['s'] as String? ?? '',
        text: j['t'] as String? ?? '',
        ts: (j['ts'] as num?)?.toInt() ?? 0,
        readThrough: (j['rt'] as num?)?.toInt(),
        avatarPath: j['a'] as String?,
        avatarResource: j['ar'] as String?,
      );
}

final LocalCacheStore _storage = LocalCacheStore();

Map<String, List<BufferedNotifMessage>> _decode(String? raw) {
  try {
    final decoded = jsonDecode(raw ?? '{}') as Map<String, dynamic>;
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

String _encode(Map<String, List<BufferedNotifMessage>> map) => jsonEncode(
  map.map((k, v) => MapEntry(k, v.map((e) => e.toJson()).toList())),
);

/// SQLite transactions prevent FCM and realtime engines losing each other's rows.
Future<List<BufferedNotifMessage>> appendChatNotification(
  String chatGuid,
  BufferedNotifMessage msg, {
  String? deviceId,
}) async {
  final key = deviceId == null ? chatGuid : "$deviceId\u001f$chatGuid";
  final value = await _storage.updateMetadata(_notifBufferKey, (raw) {
    final all = _decode(raw);
    final list = all[key] ?? <BufferedNotifMessage>[];
    list.removeWhere((m) => msg.guid.isNotEmpty && m.guid == msg.guid);
    list.add(msg);
    list.sort((a, b) => a.ts.compareTo(b.ts));
    while (list.length > _maxPerChat) {
      list.removeAt(0);
    }
    all.remove(key);
    all[key] = list;
    while (all.length > 100) {
      all.remove(all.keys.first);
    }
    return _encode(all);
  });
  return _decode(value)[key] ?? [msg];
}

/// Clear only the lines acknowledged by the action; later arrivals survive.
Future<void> clearChatNotificationBuffer(
  String chatGuid, {
  int? through,
  String? deviceId,
}) async {
  await _storage.updateMetadata(_notifBufferKey, (raw) {
    final all = _decode(raw);
    final keys = all.keys
        .where(
          (k) => deviceId != null
              ? k == "$deviceId\u001f$chatGuid"
              : k == chatGuid || k.endsWith("\u001f$chatGuid"),
        )
        .toList();
    for (final key in keys) {
      if (through == null) {
        all.remove(key);
      } else {
        all[key]?.removeWhere(
          (m) => m.readThrough != null && m.readThrough! <= through,
        );
        if (all[key]?.isEmpty == true) all.remove(key);
      }
    }
    return _encode(all);
  });
}
