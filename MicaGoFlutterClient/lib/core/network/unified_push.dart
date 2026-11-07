import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:unifiedpush/unifiedpush.dart';

/// UnifiedPush (Web Push) transport for Android.
///
/// The user picks a distributor on the phone — ntfy, NextPush, Sunup, or the
/// embedded FCM distributor bundled in this app ("FCM (Google Play)"). The
/// distributor hands us an endpoint plus RFC 8291 keys; we register that as
/// the device's `unifiedpush` push token and the Mac encrypts every push to
/// those keys. The connector library decrypts on receipt, so the push service
/// (ntfy server, Google) only ever relays ciphertext.
///
/// Like FCM, the push is a wake/awareness signal: the payload is the same flat
/// data map, shown through the shared local-notification path, and real data
/// still arrives through WebSocket + delta sync.

const String unifiedPushInstance = 'micago';

/// Last endpoint the distributor issued, JSON-encoded as the server's
/// `pushToken` shape. Persisted so an endpoint delivered to a headless engine
/// is registered the next time the app has a connection.
const String unifiedPushTokenKey = 'micago.unifiedpush.token.v1';

/// User choice in Settings → Notifications → Push service:
/// `up:<package>` (a specific distributor), `fcm` (existing Firebase
/// project, the default), or `off`.
const String pushTransportKey = 'micago.push.transport.v1';

/// Pure: the WebPush subscription JSON the server validates. Returns null when
/// the distributor did not provide encryption keys (the server requires them).
String? unifiedPushToken(String url, String? pubKey, String? auth) {
  final endpoint = url.trim();
  final p256dh = pubKey?.trim() ?? '';
  final secret = auth?.trim() ?? '';
  if (endpoint.isEmpty || p256dh.isEmpty || secret.isEmpty) return null;
  return jsonEncode({'endpoint': endpoint, 'p256dh': p256dh, 'auth': secret});
}

/// Pure: decodes a decrypted push into the flat data map shared with FCM.
/// Undecryptable or non-JSON content is dropped — never shown raw.
Map<String, dynamic>? unifiedPushData(Uint8List content, bool decrypted) {
  if (!decrypted) return null;
  try {
    final decoded = jsonDecode(utf8.decode(content));
    if (decoded is Map<String, dynamic>) return decoded;
  } catch (_) {}
  return null;
}

/// Pure: the distributor host for display ("via ntfy.example.com").
String? unifiedPushHost(String? token) {
  if (token == null || token.isEmpty) return null;
  try {
    final decoded = jsonDecode(token);
    if (decoded is Map && decoded['endpoint'] is String) {
      final host = Uri.tryParse(decoded['endpoint'] as String)?.host ?? '';
      return host.isEmpty ? null : host;
    }
  } catch (_) {}
  return null;
}

/// Pure: friendly label for a distributor package id. This app's own id (with
/// any build suffix) appears in the list because the embedded FCM distributor
/// is bundled.
String distributorLabel(String id) {
  if (id.startsWith(micaGoAndroidPackage)) return 'FCM (Google Play)';
  return switch (id) {
    'io.heckel.ntfy' => 'ntfy',
    'org.unifiedpush.distributor.nextpush' => 'NextPush',
    'org.unifiedpush.distributor.sunup' => 'Sunup',
    _ => id,
  };
}

const String micaGoAndroidPackage = 'com.micago.message.mica_go';

/// Hooks the live app installs; a headless engine leaves them null.
class UnifiedPushBridge {
  static void Function(String token)? onEndpoint;
  static void Function()? onUnregistered;

  /// Returns true when a foreground socket already delivered this event.
  static bool Function(Map<String, dynamic> data)? onForegroundMessage;

  /// Shows the notification; set to the shared local-notification renderer.
  static Future<void> Function(Map<String, dynamic> data)? showNotification;

  /// Persist/read the last token (SecureStore in the app).
  static Future<void> Function(String? token)? persistToken;

  /// Re-runs push setup after the user changes the push service.
  static Future<void> Function()? restart;
}

bool _initialized = false;

bool get unifiedPushSupported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Must run in `main()` before `runApp`: when a push arrives while the app is
/// killed, the connector starts a fresh engine at the default entrypoint and
/// delivers the message to the callbacks registered here.
Future<void> initializeUnifiedPush() async {
  if (!unifiedPushSupported || _initialized) return;
  _initialized = true;
  try {
    await UnifiedPush.initialize(
      onNewEndpoint: (endpoint, instance) {
        if (instance != unifiedPushInstance) return;
        final token = unifiedPushToken(
          endpoint.url,
          endpoint.pubKeySet?.pubKey,
          endpoint.pubKeySet?.auth,
        );
        if (token == null) {
          debugPrint('UnifiedPush: endpoint without WebPush keys; ignored');
          return;
        }
        unawaited(UnifiedPushBridge.persistToken?.call(token));
        UnifiedPushBridge.onEndpoint?.call(token);
      },
      onRegistrationFailed: (reason, instance) {
        debugPrint('UnifiedPush: registration failed ($reason)');
      },
      onUnregistered: (instance) {
        if (instance != unifiedPushInstance) return;
        unawaited(UnifiedPushBridge.persistToken?.call(null));
        UnifiedPushBridge.onUnregistered?.call();
      },
      onMessage: (message, instance) {
        if (instance != unifiedPushInstance) return;
        final data = unifiedPushData(message.content, message.decrypted);
        if (data == null) return;
        if (UnifiedPushBridge.onForegroundMessage?.call(data) == true) return;
        unawaited(UnifiedPushBridge.showNotification?.call(data));
      },
    );
  } catch (e) {
    debugPrint('UnifiedPush: initialize failed ($e)');
  }
}

Future<List<String>> unifiedPushDistributors() async {
  if (!unifiedPushSupported) return const [];
  try {
    return await UnifiedPush.getDistributors();
  } catch (_) {
    return const [];
  }
}

/// Registers only with the distributor explicitly selected by the user.
Future<bool> registerUnifiedPush({
  required String vapidPublicKey,
  required String distributor,
}) async {
  if (!unifiedPushSupported) return false;
  try {
    if (distributor.isEmpty) return false;
    await UnifiedPush.saveDistributor(distributor);
    await UnifiedPush.register(
      instance: unifiedPushInstance,
      vapid: vapidPublicKey,
    );
    return true;
  } catch (e) {
    debugPrint('UnifiedPush: register failed ($e)');
    return false;
  }
}

Future<void> unregisterUnifiedPush() async {
  if (!unifiedPushSupported) return;
  try {
    await UnifiedPush.unregister(unifiedPushInstance);
  } catch (_) {}
}
