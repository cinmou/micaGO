import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../network/device_identity.dart' show kAppVersion;
import '../storage/local_cache_store.dart';
import '../storage/secure_store.dart';

/// micaGO settings backup/restore (C54). A `.micagobak` file is a plain zip:
///
///   manifest.json          — app/type/version + created-at
///   settings.json          — all backed-up preferences (incl. server token)
///   assets/chat-background.*
///   assets/custom-avatars/*
///
/// Backs up **settings only** — never chat history, media, notification buffers,
/// realtime diagnostics, the FCM token, or the device id (which is dropped so the
/// restored install registers as a new device in the server's Paired Devices).
class BackupService {
  final SecureStore store;
  final LocalCacheStore cache;
  BackupService({required this.store, required this.cache});

  static const backupExtension = 'micagobak';
  static const _formatVersion = 1;
  static const _avatarPrefix = 'custom_avatar:';
  static const _chatBackgroundKey = 'micago.theme.chatBackgroundPath';
  static const _sidebarWidthKey = 'tablet_sidebar_width';

  /// SecureStore keys included in a backup. The connection profile carries the
  /// bearer token + routes; the rest are appearance/message/notification prefs.
  static const _secureKeys = <String>[
    'micago.connection_profile.v1', // server url + routes + selected + token
    'micago.contacts_matching_enabled.v1',
    'micago.theme.mode',
    'micago.theme.color',
    'micago.theme.lang',
    'micago.theme.chatBackgroundPath',
    'micago.muted_chats.v1',
    'micago.in_app_notifications_enabled.v1',
    'micago.keepalive.v1',
    'micago.message_display_prefs.v1',
  ];

  String suggestedFileName() {
    final ts = DateTime.now();
    final stamp =
        '${ts.year}${_pad2(ts.month)}${_pad2(ts.day)}-${_pad2(ts.hour)}${_pad2(ts.minute)}';
    return 'micaGO-settings-$stamp.$backupExtension';
  }

  static String _pad2(int n) => n.toString().padLeft(2, '0');

  // --- Export ---------------------------------------------------------------

  Future<Uint8List> exportBackup() async {
    final archive = Archive();
    final settings = <String, dynamic>{};

    final secure = <String, String>{};
    for (final key in _secureKeys) {
      final value = await store.readValue(key);
      if (value != null && value.isNotEmpty) secure[key] = value;
    }
    settings['secure'] = secure;

    final sidebar = await cache.readMetadata(_sidebarWidthKey);
    if (sidebar != null) settings['sidebarWidth'] = sidebar;

    settings['chatFlags'] = await cache.exportChatFlags();
    settings['hiddenMessages'] = (await cache.hiddenMessageGuids()).toList();

    // Chat background asset.
    final bgPath = secure[_chatBackgroundKey];
    if (bgPath != null && bgPath.isNotEmpty) {
      final file = File(bgPath);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        final ext = p.extension(bgPath);
        final name = 'assets/chat-background${ext.isEmpty ? '.jpg' : ext}';
        archive.addFile(ArchiveFile.bytes(name, bytes));
        settings['chatBackgroundAsset'] = name;
      }
    }

    // Custom avatar assets (key → asset path inside the zip).
    final avatarMeta = await cache.readMetadataWithPrefix(_avatarPrefix);
    final avatarAssets = <String, String>{};
    for (final entry in avatarMeta.entries) {
      final avatarKey = entry.key.substring(_avatarPrefix.length);
      final file = File(entry.value);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        final name = 'assets/custom-avatars/${p.basename(entry.value)}';
        archive.addFile(ArchiveFile.bytes(name, bytes));
        avatarAssets[avatarKey] = name;
      }
    }
    settings['customAvatars'] = avatarAssets;

    archive.addFile(ArchiveFile.string('settings.json', jsonEncode(settings)));
    archive.addFile(
      ArchiveFile.string(
        'manifest.json',
        jsonEncode({
          'app': 'micaGO',
          'type': 'settings-backup',
          'version': _formatVersion,
          'appVersion': kAppVersion,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
        }),
      ),
    );
    return ZipEncoder().encodeBytes(archive);
  }

  // --- Inspect (for the confirmation summary) -------------------------------

  static BackupSummary inspect(Uint8List zipBytes) {
    final archive = _decode(zipBytes);
    final manifestFile = archive.findFile('manifest.json');
    if (manifestFile == null) {
      throw const BackupException('This file is not a micaGO settings backup.');
    }
    Map<String, dynamic> manifest;
    try {
      manifest = (jsonDecode(utf8.decode(manifestFile.content)) as Map)
          .cast<String, dynamic>();
    } catch (_) {
      throw const BackupException('The backup manifest is unreadable.');
    }
    if (manifest['type'] != 'settings-backup') {
      throw const BackupException('This file is not a micaGO settings backup.');
    }
    final version = manifest['version'];
    if (version is! int || version > _formatVersion) {
      throw BackupException(
        'This backup was made by a newer micaGO version (v$version).',
      );
    }
    final settings = _readSettings(archive);
    final secure = (settings['secure'] as Map?)?.cast<String, dynamic>() ?? {};
    final avatars =
        (settings['customAvatars'] as Map?)?.cast<String, dynamic>() ?? {};
    return BackupSummary(
      appVersion: (manifest['appVersion'] as String?) ?? '',
      createdAt: DateTime.tryParse((manifest['createdAt'] as String?) ?? ''),
      hasServer: secure.containsKey('micago.connection_profile.v1'),
      hasAppearance: secure.keys.any((k) => k.startsWith('micago.theme.')),
      hasMessageDisplay: secure.containsKey('micago.message_display_prefs.v1'),
      hasChatBackground: settings['chatBackgroundAsset'] != null,
      customAvatarCount: avatars.length,
      mutedCount: _jsonListLen(secure['micago.muted_chats.v1']),
      pinnedHiddenCount: (settings['chatFlags'] as Map?)?.length ?? 0,
      hiddenMessageCount: (settings['hiddenMessages'] as List?)?.length ?? 0,
    );
  }

  // --- Apply ----------------------------------------------------------------

  Future<void> applyBackup(Uint8List zipBytes) async {
    final archive = _decode(zipBytes);
    // Validate first (throws on bad/newer backups).
    inspect(zipBytes);
    final settings = _readSettings(archive);
    final secure = (settings['secure'] as Map?)?.cast<String, dynamic>() ?? {};

    for (final entry in secure.entries) {
      // The stored background path is device-specific; it's rewritten below from
      // the restored asset, so skip it here.
      if (entry.key == _chatBackgroundKey) continue;
      if (entry.value is String) {
        await store.writeValue(entry.key, entry.value as String);
      }
    }

    if (settings['sidebarWidth'] is String) {
      await cache.writeMetadata(_sidebarWidthKey, settings['sidebarWidth']);
    }

    for (final guid in (settings['hiddenMessages'] as List? ?? const [])) {
      if (guid is String && guid.isNotEmpty) {
        await cache.setMessageHidden(guid, true);
      }
    }

    final chatFlags = <String, Map<String, int>>{};
    final rawFlags = (settings['chatFlags'] as Map?)?.cast<String, dynamic>();
    if (rawFlags != null) {
      for (final e in rawFlags.entries) {
        final flags = (e.value as Map).cast<String, dynamic>();
        chatFlags[e.key] = {
          'pinned': (flags['pinned'] as int?) ?? 0,
          'hidden': (flags['hidden'] as int?) ?? 0,
          'always_visible': (flags['always_visible'] as int?) ?? 0,
        };
      }
    }
    await cache.setPendingChatFlags(chatFlags);

    // Restore the chat background file, then point the pref at its new path.
    final bgAsset = settings['chatBackgroundAsset'] as String?;
    if (bgAsset != null) {
      final file = archive.findFile(bgAsset);
      if (file != null) {
        final dir = await getApplicationSupportDirectory();
        final bgDir = Directory(p.join(dir.path, 'chat-backgrounds'));
        await bgDir.create(recursive: true);
        final ext = p.extension(bgAsset);
        final dest = File(
          p.join(
            bgDir.path,
            'chat_background_${DateTime.now().millisecondsSinceEpoch}$ext',
          ),
        );
        await dest.writeAsBytes(file.content);
        await store.writeValue(_chatBackgroundKey, dest.path);
      }
    } else {
      await store.deleteValue(_chatBackgroundKey);
    }

    // Restore custom avatar files + their metadata pointers.
    final avatars =
        (settings['customAvatars'] as Map?)?.cast<String, dynamic>() ?? {};
    if (avatars.isNotEmpty) {
      final dir = await getApplicationSupportDirectory();
      final avatarDir = Directory(p.join(dir.path, 'custom-avatars'));
      await avatarDir.create(recursive: true);
      for (final entry in avatars.entries) {
        final assetName = entry.value as String;
        final file = archive.findFile(assetName);
        if (file == null) continue;
        final dest = File(p.join(avatarDir.path, p.basename(assetName)));
        await dest.writeAsBytes(file.content);
        await cache.writeMetadata('$_avatarPrefix${entry.key}', dest.path);
      }
    }

    // Drop the device id so the restored install registers as a NEW device
    // (privacy-friendly — the old device row stays untouched).
    await cache.deleteMetadata('device_id');
  }

  static Archive _decode(Uint8List zipBytes) {
    try {
      return ZipDecoder().decodeBytes(zipBytes);
    } catch (_) {
      throw const BackupException('The file is not a valid backup archive.');
    }
  }

  static Map<String, dynamic> _readSettings(Archive archive) {
    final file = archive.findFile('settings.json');
    if (file == null) {
      throw const BackupException('The backup is missing its settings.');
    }
    try {
      return (jsonDecode(utf8.decode(file.content)) as Map)
          .cast<String, dynamic>();
    } catch (_) {
      throw const BackupException('The backup settings are unreadable.');
    }
  }

  static int _jsonListLen(String? raw) {
    if (raw == null || raw.isEmpty) return 0;
    try {
      final v = jsonDecode(raw);
      return v is List ? v.length : 0;
    } catch (_) {
      return 0;
    }
  }
}

class BackupSummary {
  final String appVersion;
  final DateTime? createdAt;
  final bool hasServer;
  final bool hasAppearance;
  final bool hasMessageDisplay;
  final bool hasChatBackground;
  final int customAvatarCount;
  final int mutedCount;
  final int pinnedHiddenCount;
  final int hiddenMessageCount;

  const BackupSummary({
    required this.appVersion,
    required this.createdAt,
    required this.hasServer,
    required this.hasAppearance,
    required this.hasMessageDisplay,
    required this.hasChatBackground,
    required this.customAvatarCount,
    required this.mutedCount,
    required this.pinnedHiddenCount,
    required this.hiddenMessageCount,
  });
}

class BackupException implements Exception {
  final String message;
  const BackupException(this.message);
  @override
  String toString() => message;
}
