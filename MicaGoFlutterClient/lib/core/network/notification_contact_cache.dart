import 'dart:convert';
import 'dart:io';

import '../storage/secure_store.dart';

/// C60: a small persisted handle → {contact name, avatar file} cache so the
/// **FCM background isolate** can title a push with the on-device contact name
/// and show the contact's photo. The isolate has no ContactsService (and may
/// run in a fresh process), so the main isolate writes this cache whenever the
/// chat list + contacts are available, and the isolate only reads it.
///
/// Storage is SecureStore (already proven to work from the background isolate —
/// the muted-chats check uses it there). Avatar bytes live as small PNG files;
/// only their paths are stored here.
const String notificationContactCacheKey = 'micago.notif_contact_cache.v1';

/// Hard cap so the cache can't grow unbounded on huge chat lists.
const int notificationContactCacheMax = 300;

class NotificationContact {
  final String? name;
  final String? avatarPath;
  const NotificationContact({this.name, this.avatarPath});
}

/// Handles must compare the same on both sides: trim + lowercase (emails);
/// phone numbers keep their exact server format, which both the chat list and
/// the push payload take verbatim from chat.db's handle id.
String normalizeNotificationHandle(String handle) => handle.trim().toLowerCase();

/// Pure: serializes the cache to its stored JSON form (testable).
String encodeNotificationContactCache(Map<String, NotificationContact> entries) {
  final out = <String, dynamic>{};
  for (final e in entries.entries) {
    if (out.length >= notificationContactCacheMax) break;
    final key = normalizeNotificationHandle(e.key);
    if (key.isEmpty) continue;
    final name = e.value.name?.trim() ?? '';
    final avatar = e.value.avatarPath?.trim() ?? '';
    if (name.isEmpty && avatar.isEmpty) continue;
    out[key] = {
      if (name.isNotEmpty) 'n': name,
      if (avatar.isNotEmpty) 'a': avatar,
    };
  }
  return jsonEncode(out);
}

/// Pure: extracts one handle's entry from the stored JSON (testable). Avatar
/// file existence is checked by the caller-facing [lookupNotificationContact].
NotificationContact? decodeNotificationContact(String? raw, String? handle) {
  final key = normalizeNotificationHandle(handle ?? '');
  if (key.isEmpty || raw == null || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;
    final entry = decoded[key];
    if (entry is! Map) return null;
    final name = (entry['n'] as String?)?.trim();
    final avatar = (entry['a'] as String?)?.trim();
    if ((name == null || name.isEmpty) && (avatar == null || avatar.isEmpty)) {
      return null;
    }
    return NotificationContact(name: name, avatarPath: avatar);
  } catch (_) {
    return null;
  }
}

/// Serializes and writes the whole cache (main isolate).
Future<void> writeNotificationContactCache(
  SecureStore store,
  Map<String, NotificationContact> entries,
) async {
  await store.writeValue(
    notificationContactCacheKey,
    encodeNotificationContactCache(entries),
  );
}

/// Looks up one handle (background isolate — builds its own SecureStore).
/// Returns null when unknown; a stale avatar path whose file no longer exists
/// is dropped (name still returned).
Future<NotificationContact?> lookupNotificationContact(String? handle) async {
  try {
    final raw = await SecureStore().readValue(notificationContactCacheKey);
    final entry = decodeNotificationContact(raw, handle);
    if (entry == null) return null;
    var avatar = entry.avatarPath;
    if (avatar != null && avatar.isNotEmpty && !File(avatar).existsSync()) {
      avatar = null;
    }
    if ((entry.name == null || entry.name!.isEmpty) &&
        (avatar == null || avatar.isEmpty)) {
      return null;
    }
    return NotificationContact(name: entry.name, avatarPath: avatar);
  } catch (_) {
    return null;
  }
}
