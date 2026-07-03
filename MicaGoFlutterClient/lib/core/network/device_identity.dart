import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// App version embedded in the device label so the Companion can show which
/// client build is connected (C19). Bump alongside pubspec `version`.
const String kAppVersion = '0.55.0';

/// Generates a stable, client-side device id (C21u). Persisted locally and sent
/// on **every** registration so the server upserts the same device row instead
/// of creating a duplicate on each reconnect/debug-refresh. Not derived from any
/// private hardware identifier — just a random opaque token.
String generateStableDeviceId() {
  final rng = Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return 'flutter-$hex';
}

/// The device's real name for the Companion's Paired Devices list (C53).
///   • iOS → the user-set device name ("Alex's iPhone").
///   • Android → "{manufacturer} {model}" (the OS doesn't expose the user-set
///     name without a special permission), e.g. "Google Pixel 7".
/// Falls back to the old generic label if the platform lookup fails.
Future<String> resolveDeviceName() async {
  final fallback = 'micaGO on ${defaultTargetPlatform.name}';
  if (kIsWeb) return 'micaGO Web';
  try {
    final info = DeviceInfoPlugin();
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        final name = (await info.iosInfo).name.trim();
        return name.isEmpty ? fallback : name;
      case TargetPlatform.android:
        final a = await info.androidInfo;
        final model = a.model.trim();
        final brand = (a.manufacturer).trim();
        if (model.isEmpty) return brand.isEmpty ? 'Android device' : brand;
        if (brand.isNotEmpty &&
            !model.toLowerCase().startsWith(brand.toLowerCase())) {
          return '$brand $model';
        }
        return model;
      default:
        return fallback;
    }
  } catch (_) {
    return fallback;
  }
}

/// Maps the Flutter runtime platform to the server's accepted device platform
/// set (windows, android, ios, harmonyos, web, unknown).
String serverPlatformFor(TargetPlatform platform, {bool isWeb = false}) {
  if (isWeb) return 'web';
  switch (platform) {
    case TargetPlatform.android:
      return 'android';
    case TargetPlatform.iOS:
      return 'ios';
    case TargetPlatform.windows:
      return 'windows';
    default:
      return 'unknown';
  }
}

/// Builds the `/api/devices/register` body — a SMALL, non-private identity:
/// a display name, platform, app version, connection [mode] ('lan' or
/// 'lan_public'), clientType=flutter, and the push capability. No contacts,
/// tokens, or message data. [id] is the stable client device id; the server
/// updates the existing record (upsert) rather than creating a new one (C21u).
Map<String, Object?> buildDeviceRegistration({
  required String name,
  required String platform,
  required String id,
  String appVersion = kAppVersion,
  String mode = 'lan',
  String pushProvider = 'none',
  String? pushToken,
  bool pushEnabled = false,
  bool background = false,
}) {
  final label = name.trim().isEmpty ? 'micaGO client' : name.trim();
  return {
    'id': id,
    // The version is its own field now (the Companion composes
    // "{name} - micaGO {version}"), so the name stays clean.
    'name': label,
    'appVersion': appVersion,
    'platform': platform,
    'mode': mode,
    'clientType': 'flutter',
    'pushProvider': pushProvider,
    // C22: include the FCM token when push is configured so the server can wake
    // this device. Empty/absent → the server keeps push disabled for it.
    if (pushToken != null && pushToken.isNotEmpty) 'pushToken': pushToken,
    'pushEnabled': pushEnabled,
    'background': background,
  };
}
