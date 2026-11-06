import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as fc;
import 'package:path_provider/path_provider.dart';

import '../../core/storage/secure_store.dart';
import 'contact_identity.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/platform/linux_desktop.dart';
import 'linux_contact_import.dart';

enum ContactsStatus { disabled, requesting, denied, ready }

/// Local contact matching. Mobile system contacts are read-only and kept in
/// memory. Linux stores imported names, handles and photo references locally; neither
/// source is uploaded. Both are clearable through [disable].
class ContactsService extends ChangeNotifier {
  final SecureStore store;

  ContactsService({required this.store});

  ContactsStatus status = ContactsStatus.disabled;
  ContactIndex index = const ContactIndex.empty();
  String? error;
  List<ContactIdentity> _linuxContacts = [];
  Future<void> _linuxUpdate = Future<void>.value();
  final _linuxAvatarFiles = <String, String>{};
  static final _avatarName = RegExp(r'^[a-f0-9]{64}\.png$');
  int get importedContactCount =>
      _linuxContacts.map((c) => c.id).toSet().length;

  Future<File> _linuxContactsFile() async => File(
    '${(await getApplicationSupportDirectory()).path}/linux-contacts.json',
  );

  // Reopening settings during a large import must not start competing writes.
  Future<T> _queueLinuxUpdate<T>(Future<T> Function() update) {
    final operation = _linuxUpdate.then((_) => update());
    _linuxUpdate = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return operation;
  }

  Future<int> importLinuxVCard(String text) async {
    if (!isLinuxDesktop) throw UnsupportedError('Linux only');
    return _queueLinuxUpdate(() async {
      final staging = await Directory.systemTemp.createTemp('micago-contacts-');
      try {
        final result = await _mergeTextInBackground(
          text,
          _linuxContacts,
          staging.path,
        );
        await _saveLinuxContacts(result);
        return result.imported;
      } finally {
        await staging.delete(recursive: true);
      }
    });
  }

  Future<({int imported, int skipped, int photoErrors})> importLinuxVCardFile(
    String path,
  ) async {
    if (!isLinuxDesktop) throw UnsupportedError('Linux only');
    return _queueLinuxUpdate(() async {
      final staging = await Directory.systemTemp.createTemp('micago-contacts-');
      try {
        final result = await _mergeFileInBackground(
          path,
          _linuxContacts,
          staging.path,
        );
        final photoErrors = await _saveLinuxContacts(result);
        return (
          imported: result.imported,
          skipped: result.skipped,
          photoErrors: photoErrors,
        );
      } finally {
        await staging.delete(recursive: true);
      }
    });
  }

  Future<int> _saveLinuxContacts(LinuxContactImportResult result) async {
    final file = await _linuxContactsFile();
    await file.parent.create(recursive: true);
    final avatarDirectory = Directory(
      '${file.parent.path}/linux-contact-avatars',
    );
    final importedAvatars = <String, String>{};
    var photoErrors = result.photoErrors;
    for (final photo in result.stagedPhotos.entries) {
      for (final path in photo.value.reversed) {
        Uint8List bytes;
        try {
          bytes = await _contactThumbnail(path);
        } catch (_) {
          photoErrors++;
          continue;
        }
        await avatarDirectory.create(recursive: true);
        final name = '${sha256.convert(bytes)}.png';
        final avatar = File('${avatarDirectory.path}/$name');
        if (!await avatar.exists()) {
          final temporary = File('${avatar.path}.tmp');
          await temporary.writeAsBytes(bytes, flush: true);
          await temporary.rename(avatar.path);
        }
        importedAvatars[photo.key] = name;
        break;
      }
    }
    final contacts = [
      for (final contact in result.contacts)
        ContactIdentity(
          id: contact.id,
          displayName: contact.displayName,
          phones: contact.phones,
          emails: contact.emails,
          avatarFile: importedAvatars[contact.id] ?? contact.avatarFile,
        ),
    ];
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode([
        for (final c in contacts)
          {
            'id': c.id,
            'name': c.displayName,
            'phones': c.phones,
            'emails': c.emails,
            if (c.avatarFile != null) 'avatar': c.avatarFile,
          },
      ]),
      flush: true,
    );
    await temporary.rename(file.path);
    await store.setContactsMatchingEnabled(true);
    _linuxContacts = contacts;
    _refreshLinuxAvatars();
    index = ContactIndex.fromContacts(_linuxContacts);
    status = ContactsStatus.ready;
    error = null;
    notifyListeners();
    // The index is committed before obsolete immutable images are removed.
    if (await avatarDirectory.exists()) {
      final retained = _linuxAvatarFiles.values.toSet();
      await for (final entry in avatarDirectory.list(followLinks: false)) {
        if (entry is File && !retained.contains(entry.uri.pathSegments.last)) {
          try {
            await entry.delete();
          } on FileSystemException {
            /* Retry on the next import. */
          }
        }
      }
    }
    return photoErrors;
  }

  void _refreshLinuxAvatars() {
    _linuxAvatarFiles.clear();
    for (final contact in _linuxContacts) {
      final name = contact.avatarFile;
      if (name != null && _avatarName.hasMatch(name)) {
        _linuxAvatarFiles[contact.id] = name;
      }
    }
    _thumbCache.clear();
    _thumbMisses.clear();
  }

  bool get isReady => status == ContactsStatus.ready;
  bool get isSupported =>
      isLinuxDesktop ||
      !kIsWeb &&
          switch (defaultTargetPlatform) {
            TargetPlatform.android ||
            TargetPlatform.iOS ||
            TargetPlatform.macOS => true,
            _ => false,
          };

  /// On launch: if the user previously enabled matching and permission is still
  /// granted, silently load. Never prompts here.
  Future<void> bootstrap() async {
    if (isLinuxDesktop) {
      try {
        final file = await _linuxContactsFile();
        if (await file.exists()) {
          final rows = jsonDecode(await file.readAsString()) as List;
          _linuxContacts = rows
              .map(
                (row) => ContactIdentity(
                  id: row['id'] as String,
                  displayName: row['name'] as String,
                  phones: (row['phones'] as List).cast<String>(),
                  emails: (row['emails'] as List).cast<String>(),
                  avatarFile: row['avatar'] as String?,
                ),
              )
              .toList();
        }
        _refreshLinuxAvatars();
        if (await store.contactsMatchingEnabled() &&
            _linuxContacts.isNotEmpty) {
          index = ContactIndex.fromContacts(_linuxContacts);
          status = ContactsStatus.ready;
        } else {
          index = const ContactIndex.empty();
          status = ContactsStatus.disabled;
        }
      } catch (_) {
        index = const ContactIndex.empty();
        status = ContactsStatus.denied;
        error = MicaLocalizations.current.t('contacts.readFailed');
      }
      notifyListeners();
      return;
    }
    if (!isSupported || !await store.contactsMatchingEnabled()) {
      status = ContactsStatus.disabled;
      notifyListeners();
      return;
    }
    try {
      if (await fc.FlutterContacts.permissions.has(fc.PermissionType.read)) {
        await _load();
      } else {
        status = ContactsStatus.disabled;
      }
    } catch (_) {
      status = ContactsStatus.disabled;
    }
    notifyListeners();
  }

  /// Prompts for read-only contacts permission and loads on success.
  Future<void> enable() async {
    if (isLinuxDesktop) {
      await _queueLinuxUpdate(() async {
        if (_linuxContacts.isEmpty) return;
        await store.setContactsMatchingEnabled(true);
        index = ContactIndex.fromContacts(_linuxContacts);
        status = ContactsStatus.ready;
        notifyListeners();
      });
      return;
    }
    status = ContactsStatus.requesting;
    error = null;
    notifyListeners();

    fc.PermissionStatus result;
    try {
      result = await fc.FlutterContacts.permissions.request(
        fc.PermissionType.read,
      );
    } catch (_) {
      status = ContactsStatus.denied;
      error = MicaLocalizations.current.t('contacts.permissionFailed');
      notifyListeners();
      return;
    }

    final granted =
        result == fc.PermissionStatus.granted ||
        result == fc.PermissionStatus.limited;
    if (!granted) {
      status = ContactsStatus.denied;
      await store.setContactsMatchingEnabled(false);
      notifyListeners();
      return;
    }

    await store.setContactsMatchingEnabled(true);
    await _load();
    notifyListeners();
  }

  /// Turns matching off and clears the in-memory cache.
  Future<void> disable() =>
      isLinuxDesktop ? _queueLinuxUpdate(_disable) : _disable();

  Future<void> _disable() async {
    if (isLinuxDesktop) {
      final file = await _linuxContactsFile();
      for (final candidate in [file, File('${file.path}.tmp')]) {
        if (await candidate.exists()) await candidate.delete();
      }
      final avatars = Directory('${file.parent.path}/linux-contact-avatars');
      if (await avatars.exists()) await avatars.delete(recursive: true);
      _linuxContacts = [];
      _linuxAvatarFiles.clear();
    }
    await store.setContactsMatchingEnabled(false);
    index = const ContactIndex.empty();
    _thumbCache.clear();
    _thumbMisses.clear();
    status = ContactsStatus.disabled;
    notifyListeners();
  }

  Future<void> openSettings() => fc.FlutterContacts.permissions.openSettings();

  /// Local display name for a handle/identifier, or null when unmatched.
  String? displayNameFor(String? handle) => index.displayNameFor(handle);

  /// Stable contact id for a handle (normalized phone/email), or null when
  /// contacts are off or the handle has no confident match (C21 — used to merge
  /// a contact's multiple chats; a null result means "don't merge").
  String? contactIdFor(String? handle) =>
      isReady ? index.contactIdFor(handle) : null;

  // Cache thumbnails by contact id. Imported Linux images also live on disk.
  // Remember missing photos to avoid repeated reads.
  final Map<String, Uint8List> _thumbCache = {};
  final Set<String> _thumbMisses = {};

  /// Lazily loads a contact's low-res thumbnail for a handle, cached in memory.
  /// Returns null when contacts are off, the handle is unmatched, or there is
  /// no photo. Linux reads its local normalized image. Mobile platforms fetch
  /// one contact by id requesting only `photoThumbnail`.
  Future<Uint8List?> thumbnailForHandle(String? handle) async {
    if (!isReady) return null;
    final id = index.contactIdFor(handle);
    if (id == null || id.isEmpty) return null;
    if (_thumbCache.containsKey(id)) return _thumbCache[id];
    if (_thumbMisses.contains(id)) return null;
    if (isLinuxDesktop) {
      final name = _linuxAvatarFiles[id];
      if (name == null) return null;
      try {
        final contacts = await _linuxContactsFile();
        final bytes = await File(
          '${contacts.parent.path}/linux-contact-avatars/$name',
        ).readAsBytes();
        if (!isReady || _linuxAvatarFiles[id] != name) return null;
        if (_thumbCache.length >= 128) {
          _thumbCache.remove(_thumbCache.keys.first);
        }
        _thumbCache[id] = bytes;
        return bytes;
      } on FileSystemException {
        if (_linuxAvatarFiles[id] == name) _thumbMisses.add(id);
        return null;
      }
    }
    try {
      final contact = await fc.FlutterContacts.get(
        id,
        properties: const {fc.ContactProperty.photoThumbnail},
      );
      final bytes = contact?.photo?.thumbnail;
      if (bytes != null && bytes.isNotEmpty) {
        _thumbCache[id] = bytes;
        return bytes;
      }
    } catch (_) {
      // Ignore — record a miss so we never retry a broken id in a tight loop.
    }
    _thumbMisses.add(id);
    return null;
  }

  Future<void> _load() async {
    try {
      final raw = await fc.FlutterContacts.getAll(
        properties: const {
          fc.ContactProperty.name,
          fc.ContactProperty.phone,
          fc.ContactProperty.email,
        },
      );
      final identities = raw
          .map(
            (c) => ContactIdentity(
              id: c.id ?? '',
              displayName: c.displayName ?? '',
              phones: c.phones.map((p) => p.number).toList(growable: false),
              emails: c.emails.map((e) => e.address).toList(growable: false),
            ),
          )
          .where((c) => c.displayName.trim().isNotEmpty)
          .toList(growable: false);
      index = ContactIndex.fromContacts(identities);
      status = ContactsStatus.ready;
      error = null;
    } catch (_) {
      status = ContactsStatus.denied;
      error = MicaLocalizations.current.t('contacts.readFailed');
    }
  }
}

// Keep isolate closures outside the service so queued Futures are not captured.
Future<LinuxContactImportResult> _mergeTextInBackground(
  String text,
  List<ContactIdentity> existing,
  String photoDirectory,
) => Isolate.run(
  () => mergeLinuxVCard(text, existing, photoDirectory: photoDirectory),
);

Future<LinuxContactImportResult> _mergeFileInBackground(
  String path,
  List<ContactIdentity> existing,
  String photoDirectory,
) => Isolate.run(
  () => mergeLinuxVCardFile(path, existing, photoDirectory: photoDirectory),
);

Future<Uint8List> _contactThumbnail(String path) async {
  final buffer = await ui.ImmutableBuffer.fromFilePath(path);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final scale = math.min(
      1.0,
      256 / math.max(descriptor.width, descriptor.height),
    );
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (descriptor.width * scale).round()),
      targetHeight: math.max(1, (descriptor.height * scale).round()),
    );
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw const FormatException('Cannot encode contact photo');
    }
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}
