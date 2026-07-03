import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/backup/backup_service.dart';

Uint8List _zip(Map<String, dynamic> manifest, Map<String, dynamic> settings) {
  final archive = Archive();
  archive.addFile(ArchiveFile.string('manifest.json', jsonEncode(manifest)));
  archive.addFile(ArchiveFile.string('settings.json', jsonEncode(settings)));
  return ZipEncoder().encodeBytes(archive);
}

void main() {
  group('BackupService.inspect', () {
    test('summarises a valid backup', () {
      final bytes = _zip(
        {
          'app': 'micaGO',
          'type': 'settings-backup',
          'version': 1,
          'appVersion': '0.55.0',
          'createdAt': '2026-07-01T00:00:00Z',
        },
        {
          'secure': {
            'micago.connection_profile.v1': '{"baseUrl":"x","token":"t"}',
            'micago.theme.mode': 'dark',
            'micago.message_display_prefs.v1': '{}',
            'micago.muted_chats.v1': '["a","b"]',
            'micago.fcm_options.v1': '{"projectId":"demo"}',
          },
          'chatFlags': {
            'g1': {'pinned': 1, 'hidden': 0, 'always_visible': 0},
          },
          'hiddenMessages': ['m1', 'm2', 'm3'],
          'customAvatars': {'contact_1': 'assets/custom-avatars/a.png'},
          'chatBackgroundAsset': 'assets/chat-background.jpg',
        },
      );
      final s = BackupService.inspect(bytes);
      expect(s.hasServer, isTrue);
      expect(s.hasAppearance, isTrue);
      expect(s.hasMessageDisplay, isTrue);
      expect(s.hasChatBackground, isTrue);
      expect(s.customAvatarCount, 1);
      expect(s.mutedCount, 2);
      expect(s.pinnedHiddenCount, 1);
      expect(s.hiddenMessageCount, 3);
    });

    test('rejects a non-backup zip', () {
      final bytes = _zip({'type': 'something-else'}, {});
      expect(
        () => BackupService.inspect(bytes),
        throwsA(isA<BackupException>()),
      );
    });

    test('rejects a newer format version', () {
      final bytes = _zip(
        {'app': 'micaGO', 'type': 'settings-backup', 'version': 99},
        {'secure': {}},
      );
      expect(
        () => BackupService.inspect(bytes),
        throwsA(isA<BackupException>()),
      );
    });

    test('rejects junk bytes', () {
      expect(
        () => BackupService.inspect(Uint8List.fromList([1, 2, 3, 4])),
        throwsA(isA<BackupException>()),
      );
    });
  });
}
