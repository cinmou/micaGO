import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/app_controller.dart';
import 'package:mica_go/core/network/update_check.dart';
import 'package:mica_go/core/storage/secure_store.dart';

class _MemorySecureStore implements SecureStore {
  final Map<String, String> values = {};

  @override
  Future<String?> readValue(String key) async => values[key];

  @override
  Future<void> writeValue(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> deleteValue(String key) async {
    values.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('version comparison (C74)', () {
    test('detects a newer release, ignoring a leading v', () {
      expect(isNewerVersion('v0.65.0', '0.64.0'), isTrue);
      expect(isNewerVersion('0.65.0', '0.64.0'), isTrue);
      expect(isNewerVersion('v1.0.0', '0.99.9'), isTrue);
      expect(isNewerVersion('v0.64.1', '0.64.0'), isTrue);
    });

    test('same or older releases are not offered', () {
      expect(isNewerVersion('v0.64.0', '0.64.0'), isFalse);
      expect(isNewerVersion('v0.63.9', '0.64.0'), isFalse);
      // Missing trailing parts count as zero.
      expect(isNewerVersion('v0.64', '0.64.0'), isFalse);
    });

    test('pre-release suffixes compare on the numeric part', () {
      expect(isNewerVersion('v0.65.0-beta.1', '0.64.0'), isTrue);
      expect(isNewerVersion('v0.64.0-beta.1', '0.64.0'), isFalse);
    });
  });

  group('release payload parsing (C74)', () {
    test('a newer tag reports updateAvailable with its page url', () {
      final result = resultFromReleaseJson(
        '{"tag_name":"v0.65.0","html_url":"https://example.com/r/0.65.0"}',
        '0.64.0',
      );
      expect(result.status, UpdateCheckStatus.updateAvailable);
      expect(result.latestVersion, '0.65.0');
      expect(result.releaseUrl, 'https://example.com/r/0.65.0');
    });

    test('the current tag reports upToDate', () {
      final result = resultFromReleaseJson('{"tag_name":"v0.64.0"}', '0.64.0');
      expect(result.status, UpdateCheckStatus.upToDate);
      expect(result.releaseUrl, kUpdateReleasesPage);
    });

    test('drafts and junk resolve to unknown, never to an update', () {
      expect(
        resultFromReleaseJson(
          '{"tag_name":"v9.9.9","draft":true}',
          '0.64.0',
        ).status,
        UpdateCheckStatus.unknown,
      );
      expect(
        resultFromReleaseJson('not json', '0.64.0').status,
        UpdateCheckStatus.unknown,
      );
      expect(
        resultFromReleaseJson('{"message":"rate limited"}', '0.64.0').status,
        UpdateCheckStatus.unknown,
      );
    });
  });

  group('AppController auto update checks', () {
    test('defaults enabled, respects toggle and 24h cooldown, manual always runs', () async {
      final store = _MemorySecureStore();
      final app = AppController(store: store);
      expect(app.autoCheckUpdatesEnabled, isTrue);

      var calls = 0;
      var fakeNow = DateTime.utc(2026, 11, 25, 10, 0);
      Future<UpdateCheckResult> fakeChecker(String current) async {
        calls++;
        return const UpdateCheckResult(
          status: UpdateCheckStatus.updateAvailable,
          latestVersion: '0.98.0',
          releaseUrl: 'https://example.com/r/0.98.0',
        );
      }

      // First automatic check runs and records timestamp.
      final first = await app.checkForUpdates(
        manual: false,
        checker: fakeChecker,
        now: () => fakeNow,
      );
      expect(calls, 1);
      expect(first.status, UpdateCheckStatus.updateAvailable);
      expect(app.latestUpdateCheck?.latestVersion, '0.98.0');

      // Second automatic check within 24h is throttled.
      fakeNow = fakeNow.add(const Duration(hours: 6));
      await app.checkForUpdates(
        manual: false,
        checker: fakeChecker,
        now: () => fakeNow,
      );
      expect(calls, 1);

      // Manual check bypasses the 24h cooldown.
      await app.checkForUpdates(
        manual: true,
        checker: fakeChecker,
        now: () => fakeNow,
      );
      expect(calls, 2);

      // Turning auto-check off persists and skips automatic checks even after 24h.
      await app.setAutoCheckUpdatesEnabled(false);
      expect(app.autoCheckUpdatesEnabled, isFalse);
      expect(store.values[AppController.autoCheckUpdatesStorageKey], '0');

      fakeNow = fakeNow.add(const Duration(hours: 30));
      await app.checkForUpdates(
        manual: false,
        checker: fakeChecker,
        now: () => fakeNow,
      );
      expect(calls, 2);

      // Re-enabling lets the next automatic check run once cooldown elapsed.
      await app.setAutoCheckUpdatesEnabled(true);
      await app.checkForUpdates(
        manual: false,
        checker: fakeChecker,
        now: () => fakeNow,
      );
      expect(calls, 3);
    });
  });
}
