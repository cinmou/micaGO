import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/network/device_identity.dart';

void main() {
  group('device identity (C19 connected-device visibility)', () {
    test('platform maps to the server-accepted set', () {
      expect(serverPlatformFor(TargetPlatform.android), 'android');
      expect(serverPlatformFor(TargetPlatform.iOS), 'ios');
      expect(serverPlatformFor(TargetPlatform.windows), 'windows');
      expect(serverPlatformFor(TargetPlatform.linux), 'unknown');
      expect(serverPlatformFor(TargetPlatform.android, isWeb: true), 'web');
    });

    test('registration body is small, non-private, and flutter clientType', () {
      final body = buildDeviceRegistration(
        name: 'Pixel 7',
        platform: 'android',
        id: 'flutter-abc',
        appVersion: '0.1.0',
        mode: 'lan_public',
      );
      expect(body['clientType'], 'flutter');
      expect(body['platform'], 'android');
      // Name is clean; the version + mode are their own fields (C21u).
      expect(body['name'], 'Pixel 7');
      expect(body['appVersion'], '0.1.0');
      expect(body['mode'], 'lan_public');
      expect(body['pushEnabled'], false);
      expect(body['pushProvider'], 'none');
      // A stable id is always sent so the server upserts (no duplicates), and
      // there are no private fields.
      expect(body['id'], 'flutter-abc');
      expect(body.keys, isNot(contains('token')));
      expect(body.keys, isNot(contains('contacts')));
    });

    test('mode defaults to lan when unspecified', () {
      final body = buildDeviceRegistration(
        name: 'Pixel 7',
        platform: 'android',
        id: 'dev-123',
      );
      expect(body['id'], 'dev-123');
      expect(body['mode'], 'lan');
    });

    test('empty name falls back to a generic label', () {
      final body = buildDeviceRegistration(
        name: '   ',
        platform: 'ios',
        id: 'dev-1',
      );
      expect(body['name'], 'micaGO client');
    });

    test('C22: push fields included when an FCM token is present', () {
      final body = buildDeviceRegistration(
        name: 'Pixel 7',
        platform: 'android',
        id: 'flutter-abc',
        pushProvider: 'fcm',
        pushToken: 'fcm-token-xyz',
        pushEnabled: true,
        background: true,
      );
      expect(body['pushProvider'], 'fcm');
      expect(body['pushToken'], 'fcm-token-xyz');
      expect(body['pushEnabled'], true);
      expect(body['background'], true);
    });

    test('C22: no pushToken key when Firebase is not configured', () {
      final body = buildDeviceRegistration(
        name: 'Pixel 7',
        platform: 'android',
        id: 'flutter-abc',
      );
      // Optional Firebase: default is no-push, and the token key is omitted.
      expect(body['pushProvider'], 'none');
      expect(body['pushEnabled'], false);
      expect(body['background'], false);
      expect(body.containsKey('pushToken'), isFalse);
    });
  });
}
