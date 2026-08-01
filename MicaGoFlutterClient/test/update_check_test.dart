import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/network/update_check.dart';

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
}
