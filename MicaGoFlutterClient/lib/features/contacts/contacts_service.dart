import 'package:flutter/foundation.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as fc;

import '../../core/storage/secure_store.dart';
import 'contact_identity.dart';
import '../../core/l10n/app_localizations.dart';

enum ContactsStatus { disabled, requesting, denied, ready }

/// Read-only local contacts matching. Requests `READ_CONTACTS` only when the
/// user explicitly enables it, builds an in-memory [ContactIndex], and never
/// writes, uploads, or persists the contact book (only an opt-in flag is
/// stored). Clearable via [disable].
class ContactsService extends ChangeNotifier {
  final SecureStore store;

  ContactsService({required this.store});

  ContactsStatus status = ContactsStatus.disabled;
  ContactIndex index = const ContactIndex.empty();
  String? error;

  bool get isReady => status == ContactsStatus.ready;
  bool get isSupported =>
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
  Future<void> disable() async {
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

  // In-memory thumbnail cache (never persisted, never uploaded). Keyed by
  // contact id; a missing photo is recorded so we don't refetch.
  final Map<String, Uint8List> _thumbCache = {};
  final Set<String> _thumbMisses = {};

  /// Lazily loads a contact's low-res thumbnail for a handle, cached in memory.
  /// Returns null when contacts are off, the handle is unmatched, or there is
  /// no photo. READ-only: fetches a single contact by id requesting only the
  /// `photoThumbnail` property (no full photo, no bulk load), so it scales to
  /// large address books.
  Future<Uint8List?> thumbnailForHandle(String? handle) async {
    if (!isReady) return null;
    final id = index.contactIdFor(handle);
    if (id == null || id.isEmpty) return null;
    if (_thumbCache.containsKey(id)) return _thumbCache[id];
    if (_thumbMisses.contains(id)) return null;
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
