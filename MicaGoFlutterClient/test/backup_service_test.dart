import 'dart:io';
import 'package:flutter/services.dart';
import 'package:mica_go/core/storage/secure_store.dart';
import 'package:mica_go/core/storage/local_cache_store.dart';
import 'dart:convert';

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
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'export and restore settings with assets preserve credentials and queues',
    () async {
      final dir = await Directory.systemTemp.createTemp('micago-backup-check-');
      addTearDown(() => dir.delete(recursive: true));
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => dir.path);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final background = File('${dir.path}/original-bg.png');
      final avatar = File('${dir.path}/original-avatar.png');
      await background.writeAsBytes([1, 2, 3]);
      await avatar.writeAsBytes([4, 5, 6]);
      final source = _Store()
        ..values.addAll({
          'micago.theme.mode': 'dark',
          'micago.theme.chatBackgroundPath': background.path,
          'micago.message_display_prefs.v1': '{"mergeTapbacks":"1"}',
          'micago.connection_profile.v1': 'source-credential',
        });
      final sourceCache = _Cache()
        ..metadata['custom_avatar:contact-1'] = avatar.path
        ..metadata['tablet_sidebar_width'] = '0.4'
        ..flags['chat-1'] = {'pinned': 1, 'always_visible': 0}
        ..hidden.add('chat-1\u001fmessage-1');
      final bytes = await BackupService(
        store: source,
        cache: sourceCache,
      ).exportBackup();
      final zip = ZipDecoder().decodeBytes(bytes);
      final settings =
          jsonDecode(utf8.decode(zip.findFile('settings.json')!.content))
              as Map;
      expect(
        (settings['secure'] as Map).containsKey('micago.connection_profile.v1'),
        isFalse,
      );
      final summary = BackupService.inspect(bytes);
      expect(summary.hasAppearance, isTrue);
      expect(summary.hasChatBackground, isTrue);
      expect(summary.customAvatarCount, 1);
      final target = _Store()
        ..values['micago.connection_profile.v1'] = 'existing-credential';
      final targetCache = _Cache()
        ..metadata['preference-outbox'] = 'pending-change';
      await BackupService(store: target, cache: targetCache).applyBackup(bytes);
      expect(target.values['micago.theme.mode'], 'dark');
      expect(
        target.values['micago.message_display_prefs.v1'],
        '{"mergeTapbacks":"1"}',
      );
      expect(
        await File(
          target.values['micago.theme.chatBackgroundPath']!,
        ).readAsBytes(),
        [1, 2, 3],
      );
      expect(
        await File(
          targetCache.metadata['custom_avatar:contact-1']!,
        ).readAsBytes(),
        [4, 5, 6],
      );
      expect(targetCache.flags['chat-1']!['pinned'], 1);
      expect(targetCache.hidden, contains('chat-1\u001fmessage-1'));
      expect(
        target.values['micago.connection_profile.v1'],
        'existing-credential',
      );
      expect(targetCache.metadata['preference-outbox'], 'pending-change');
    },
  );

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
            // Legacy local mute state may exist in old backups; it is no longer
            // reported or restored because server sync rules are authoritative.
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
      expect(s.hasServer, isFalse);
      expect(s.hasAppearance, isTrue);
      expect(s.hasMessageDisplay, isTrue);
      expect(s.hasChatBackground, isTrue);
      expect(s.customAvatarCount, 1);
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

class _Store implements SecureStore {
  final values = <String, String>{};
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

class _Cache extends LocalCacheStore {
  final metadata = <String, String>{};
  final flags = <String, Map<String, int>>{};
  final hidden = <String>{};
  @override
  Future<String?> readMetadata(String key) async => metadata[key];
  @override
  Future<void> writeMetadata(String key, String value) async {
    metadata[key] = value;
  }

  @override
  Future<void> deleteMetadata(String key) async {
    metadata.remove(key);
  }

  @override
  Future<Map<String, String>> readMetadataWithPrefix(String prefix) async =>
      Map.fromEntries(metadata.entries.where((e) => e.key.startsWith(prefix)));
  @override
  Future<Map<String, Map<String, int>>> exportChatFlags() async => flags;
  @override
  Future<Set<String>> hiddenMessageGuids() async => hidden;
  @override
  Future<void> setMessageHidden(String guid, bool value) async {
    if (value) {
      hidden.add(guid);
    } else {
      hidden.remove(guid);
    }
  }

  @override
  Future<void> setPendingChatFlags(Map<String, Map<String, int>> value) async {
    flags.addAll(value);
  }
}
