import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class IncomingSharePayload {
  final String? text;
  final String? subject;
  final String? mimeType;
  final String? targetChatGuid;
  final List<String> uris;

  const IncomingSharePayload({
    this.text,
    this.subject,
    this.mimeType,
    this.targetChatGuid,
    this.uris = const [],
  });

  bool get hasContent => (text?.trim().isNotEmpty ?? false) || uris.isNotEmpty;

  String get summary {
    if (uris.isNotEmpty) {
      return uris.length == 1 ? '1 shared file' : '${uris.length} shared files';
    }
    final value = text?.trim() ?? '';
    if (value.length <= 48) return value;
    return '${value.substring(0, 48)}...';
  }

  static IncomingSharePayload? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final uris =
        (raw['uris'] as List?)?.whereType<String>().toList() ?? const [];
    final payload = IncomingSharePayload(
      text: raw['text'] as String?,
      subject: raw['subject'] as String?,
      mimeType: raw['mimeType'] as String?,
      targetChatGuid: raw['targetChatGuid'] as String?,
      uris: uris,
    );
    return payload.hasContent ? payload : null;
  }
}

class IncomingShareService {
  IncomingShareService._();

  static const MethodChannel _channel = MethodChannel('micago/share');
  static final ValueNotifier<IncomingSharePayload?> latest =
      ValueNotifier<IncomingSharePayload?>(null);
  static bool _started = false;

  static Future<void> start() async {
    if (_started) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onShare') {
        latest.value = IncomingSharePayload.fromMap(call.arguments);
      }
    });
    try {
      latest.value = IncomingSharePayload.fromMap(
        await _channel.invokeMethod<Object?>('getInitialShare'),
      );
      if (latest.value != null) {
        unawaited(_channel.invokeMethod<void>('clearInitialShare'));
      }
    } catch (_) {
      // Non-Android platforms simply do not provide this channel.
    }
  }

  static Future<void> registerShareTargets(
    Iterable<({String guid, String title, String? avatarPath})> targets,
  ) async {
    try {
      await _channel.invokeMethod<bool>('setShareTargets', [
        for (final target in targets)
          {
            'guid': target.guid,
            'title': target.title,
            if (target.avatarPath != null) 'avatarPath': target.avatarPath,
          },
      ]);
    } catch (_) {
      // Android-only enhancement; unsupported platforms can ignore it.
    }
  }

  static void clear() {
    latest.value = null;
  }
}
