/// Pure, testable contact-matching logic (no plugin/Flutter imports).
///
/// A contact may own several handles (phone numbers + emails). We normalise
/// each handle locally and build an index so chat identifiers like
/// `+1 (555) 123-4567` or `Name@iCloud.com` map to the same local display name.
/// Normalisation is intentionally conservative (no destructive assumptions).
library;

/// Lowercases and trims an email. Returns '' if it isn't email-shaped.
String normalizeEmail(String raw) {
  final v = raw.trim().toLowerCase();
  return v.contains('@') ? v : '';
}

/// Reduces a phone string to its matching key: digits only, and (when longer
/// than 10 digits, e.g. with a country code) the last 10 digits. This tolerates
/// `+1`, spaces, dashes, and parentheses without assuming a region. Returns ''
/// for too-short input.
String normalizePhone(String raw) {
  final digits = raw.replaceAll(RegExp(r'\D'), '');
  if (digits.length < 7) return '';
  return digits.length > 10 ? digits.substring(digits.length - 10) : digits;
}

/// True if a handle looks like an email address.
bool isEmailHandle(String handle) => handle.contains('@');

/// A local contact with its handles. `displayName` is what we show.
class ContactIdentity {
  final String id;
  final String displayName;
  final List<String> phones;
  final List<String> emails;

  const ContactIdentity({
    required this.id,
    required this.displayName,
    this.phones = const [],
    this.emails = const [],
  });
}

/// An index from normalised handle → display name, built from local contacts.
class ContactIndex {
  final Map<String, String> _byEmail;
  final Map<String, String> _byPhone;
  final Map<String, String> _idByEmail;
  final Map<String, String> _idByPhone;

  const ContactIndex._(
    this._byEmail,
    this._byPhone,
    this._idByEmail,
    this._idByPhone,
  );

  const ContactIndex.empty()
    : _byEmail = const {},
      _byPhone = const {},
      _idByEmail = const {},
      _idByPhone = const {};

  bool get isEmpty => _byEmail.isEmpty && _byPhone.isEmpty;

  factory ContactIndex.fromContacts(Iterable<ContactIdentity> contacts) {
    final byEmail = <String, String>{};
    final byPhone = <String, String>{};
    final idByEmail = <String, String>{};
    final idByPhone = <String, String>{};
    for (final c in contacts) {
      final name = c.displayName.trim();
      if (name.isEmpty) continue;
      for (final e in c.emails) {
        final key = normalizeEmail(e);
        if (key.isNotEmpty) {
          byEmail.putIfAbsent(key, () => name);
          if (c.id.isNotEmpty) idByEmail.putIfAbsent(key, () => c.id);
        }
      }
      for (final p in c.phones) {
        final key = normalizePhone(p);
        if (key.isNotEmpty) {
          byPhone.putIfAbsent(key, () => name);
          if (c.id.isNotEmpty) idByPhone.putIfAbsent(key, () => c.id);
        }
      }
    }
    return ContactIndex._(byEmail, byPhone, idByEmail, idByPhone);
  }

  /// Returns the local display name for a chat identifier/handle, or null if
  /// there's no match (e.g. a group GUID, or contacts not loaded).
  String? displayNameFor(String? handle) {
    final h = handle?.trim() ?? '';
    if (h.isEmpty) return null;
    if (isEmailHandle(h)) {
      return _byEmail[normalizeEmail(h)];
    }
    final key = normalizePhone(h);
    if (key.isEmpty) return null;
    return _byPhone[key];
  }

  /// Returns the local contact id for a handle (used to lazily fetch a
  /// thumbnail by id), or null when unmatched.
  String? contactIdFor(String? handle) {
    final h = handle?.trim() ?? '';
    if (h.isEmpty) return null;
    if (isEmailHandle(h)) return _idByEmail[normalizeEmail(h)];
    final key = normalizePhone(h);
    if (key.isEmpty) return null;
    return _idByPhone[key];
  }
}
