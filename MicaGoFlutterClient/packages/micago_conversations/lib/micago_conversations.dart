import 'package:flutter/services.dart';

/// Auto-registered in foreground and notification background engines.
class AndroidConversations {
  static const channel = MethodChannel('micago/conversations');

  static Future<String?> publish({
    required String chatGuid,
    required String deviceId,
    required String title,
    required String payload,
    String? avatarPath,
    String? personName,
    String? personKey,
    String? personAvatarPath,
  }) => channel.invokeMethod<String>('publish', {
    'chatGuid': chatGuid,
    'deviceId': deviceId,
    'title': title,
    'payload': payload,
    'avatarPath': avatarPath,
    'personName': personName,
    'personKey': personKey,
    'personAvatarPath': personAvatarPath,
  });

  static Future<void> cancelThrough(int id, int through) => channel
      .invokeMethod<void>('cancelThrough', {'id': id, 'through': through});

  static Future<void> clear() => channel.invokeMethod<void>('clear');

  static Future<void> listen(void Function(String) onOpen) async {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'open' && call.arguments is String) {
        onOpen(call.arguments as String);
      }
    });
    final pending = await channel.invokeMethod<String>('takeInitial');
    if (pending != null) onOpen(pending);
  }
}
