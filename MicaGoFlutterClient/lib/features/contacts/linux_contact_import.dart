import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as fc;

import 'contact_identity.dart';

typedef LinuxContactImportResult = ({
  List<ContactIdentity> contacts,
  int imported,
  int skipped,
  Map<String, List<String>> stagedPhotos,
  int photoErrors,
});

typedef _ParsedCard = ({
  fc.Contact? contact,
  Uint8List? photo,
  bool photoError,
});

/// Parse one card at a time and stage embedded photos outside the UI isolate.
Future<LinuxContactImportResult> mergeLinuxVCardFile(
  String path,
  List<ContactIdentity> existing, {
  String? photoDirectory,
}) async {
  final merger = _ContactMerger(existing, photoDirectory);
  final reader = _CardReader();
  final lines = File(
    path,
  ).openRead().transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    final card = reader.addLine(line);
    if (card != null) merger.add(card);
  }
  final last = reader.finish();
  if (last != null) merger.add(last);
  return merger.finish();
}

/// Match by UID or known phone/email identities. Names never form identity keys.
LinuxContactImportResult mergeLinuxVCard(
  String text,
  List<ContactIdentity> existing, {
  String? photoDirectory,
}) {
  final merger = _ContactMerger(existing, photoDirectory);
  final reader = _CardReader();
  for (final line in const LineSplitter().convert(text)) {
    final card = reader.addLine(line);
    if (card != null) merger.add(card);
  }
  final last = reader.finish();
  if (last != null) merger.add(last);
  return merger.finish();
}

String _key(String value) => isEmailHandle(value)
    ? 'email:${normalizeEmail(value)}'
    : 'phone:${normalizePhone(value)}';

String _strip(String value) => value.trim().replaceFirst(
  RegExp(r'^(tel|mailto):', caseSensitive: false),
  '',
);

class _ContactMerger {
  _ContactMerger(List<ContactIdentity> existing, this.photoDirectory) {
    for (final contact in existing) {
      for (final handle in [...contact.phones, ...contact.emails]) {
        rows[_key(handle)] = contact;
        keysById.putIfAbsent(contact.id, () => <String>{}).add(_key(handle));
      }
    }
  }

  final String? photoDirectory;
  final rows = <String, ContactIdentity>{};
  final keysById = <String, Set<String>>{};
  final photos = <String, List<String>>{};
  int imported = 0;
  int skipped = 0;
  int photoErrors = 0;

  void add(_ParsedCard parsed) {
    final card = parsed.contact;
    if (card == null) {
      skipped++;
      return;
    }
    final phones = card.phones
        .map((p) => _strip(p.number))
        .where((p) => normalizePhone(p).isNotEmpty)
        .toSet();
    final emails = card.emails
        .map((e) => _strip(e.address))
        .where((e) => normalizeEmail(e).isNotEmpty)
        .toSet();
    final handles = [...phones, ...emails];
    if (handles.isEmpty) {
      skipped++;
      return;
    }
    final keys = handles.map(_key).toList()..sort();
    final previousIds = keys
        .map((key) => rows[key]?.id)
        .whereType<String>()
        .toSet();
    final uid = card.id?.trim() ?? '';
    final id = uid.isNotEmpty
        ? 'vcf:${sha256.convert(utf8.encode(uid))}'
        : previousIds.isNotEmpty
        ? previousIds.first
        : 'vcf:${sha256.convert(utf8.encode(keys.join('\n')))}';
    final name = card.displayName?.trim() ?? '';
    final displayName = name.isEmpty ? handles.first : name;
    final mergedKeys = <String>{};
    String? avatarFile;
    for (final previousId in {...previousIds, id}) {
      mergedKeys.addAll(keysById.remove(previousId) ?? const <String>{});
      final photo = photos.remove(previousId);
      if (photo != null) photos.putIfAbsent(id, () => []).addAll(photo);
    }
    for (final identityKey in mergedKeys) {
      avatarFile ??= rows[identityKey]?.avatarFile;
    }
    for (final identityKey in mergedKeys) {
      final previous = rows[identityKey]!;
      rows[identityKey] = ContactIdentity(
        id: id,
        displayName: displayName,
        phones: previous.phones,
        emails: previous.emails,
        avatarFile: avatarFile,
      );
    }
    keysById[id] = mergedKeys;
    for (final phone in phones) {
      rows[_key(phone)] = ContactIdentity(
        id: id,
        displayName: displayName,
        phones: [phone],
        avatarFile: avatarFile,
      );
    }
    for (final email in emails) {
      rows[_key(email)] = ContactIdentity(
        id: id,
        displayName: displayName,
        emails: [email],
        avatarFile: avatarFile,
      );
    }
    keysById[id]!.addAll(keys);
    if (parsed.photoError) photoErrors++;
    final photo = parsed.photo;
    if (photo != null && photoDirectory != null) {
      final directory = Directory(photoDirectory!);
      directory.createSync(recursive: true);
      final file = File('${directory.path}/${sha256.convert(photo)}');
      if (!file.existsSync()) file.writeAsBytesSync(photo);
      final candidates = photos.putIfAbsent(id, () => []);
      candidates.remove(file.path);
      candidates.add(file.path);
    }
    imported++;
  }

  LinuxContactImportResult finish() {
    if (imported == 0) throw const FormatException('No usable vCard contacts');
    final contacts = rows.entries
        .map(
          (entry) => ContactIdentity(
            id: entry.value.id,
            displayName: entry.value.displayName,
            phones: entry.key.startsWith('phone:')
                ? entry.value.phones.where((p) => _key(p) == entry.key).toList()
                : const [],
            emails: entry.key.startsWith('email:')
                ? entry.value.emails.where((e) => _key(e) == entry.key).toList()
                : const [],
            avatarFile: entry.value.avatarFile,
          ),
        )
        .toList();
    return (
      contacts: contacts,
      imported: imported,
      skipped: skipped,
      stagedPhotos: photos,
      photoErrors: photoErrors,
    );
  }
}

class _CardReader {
  _VCardFields? _fields;

  _ParsedCard? addLine(String line) {
    final boundary = line.replaceFirst('\uFEFF', '').trim().toUpperCase();
    if (boundary == 'BEGIN:VCARD') {
      final previous = finish();
      _fields = _VCardFields();
      return previous;
    }
    if (boundary == 'END:VCARD') return finish();
    _fields?.addLine(line);
    return null;
  }

  _ParsedCard? finish() {
    final fields = _fields;
    _fields = null;
    return fields?.finish();
  }
}

/// Keep photos separate so a damaged image cannot discard names and addresses.
class _VCardFields {
  static final _field = RegExp(
    r'^(?:[^:;.]+\.)?(BEGIN|END|VERSION|UID|FN|N|TEL|EMAIL|PHOTO)[;:]',
    caseSensitive: false,
  );
  final _text = StringBuffer();
  final _photos = StringBuffer();
  StringBuffer? _pending;
  bool _isPhoto = false;
  bool _quotedPrintable = false;
  bool _softBreak = false;

  void addLine(String line) {
    if (_pending != null) {
      if (_softBreak || line.startsWith(' ') || line.startsWith('\t')) {
        _append(
          line.startsWith(' ') || line.startsWith('\t')
              ? line.substring(1)
              : line,
        );
        return;
      }
      // Some vCard 2.1 exports wrap base64 without the usual leading space.
      if (_isPhoto && line.isNotEmpty && !line.contains(':')) {
        _append(line.trim());
        return;
      }
    }
    _flush();
    final match = _field.firstMatch(line);
    final colon = line.indexOf(':');
    if (match == null || colon < 0) return;
    _pending = StringBuffer();
    _isPhoto = match.group(1)!.toUpperCase() == 'PHOTO';
    final header = line.substring(0, colon).toUpperCase().replaceAll('"', '');
    _quotedPrintable =
        header.contains('ENCODING=QUOTED-PRINTABLE') ||
        header.contains('ENCODING=QP');
    _append(line);
  }

  void _append(String fragment) {
    if (_isPhoto) {
      // Compact base64 as it arrives. Huge whitespace runs can overflow the
      // general parser's whitespace regular expression.
      final colon = fragment.indexOf(':');
      if (colon >= 0) {
        _pending!.write(fragment.substring(0, colon + 1));
        fragment = fragment.substring(colon + 1);
      }
      for (final code in fragment.codeUnits) {
        if (code != 32 && code != 9 && code != 13 && code != 10) {
          _pending!.writeCharCode(code);
        }
      }
      return;
    }
    _softBreak = _quotedPrintable && fragment.endsWith('=');
    _pending!.write(
      _softBreak ? fragment.substring(0, fragment.length - 1) : fragment,
    );
  }

  void _flush() {
    if (_pending != null) {
      if (_softBreak) _pending!.write('=');
      (_isPhoto ? _photos : _text).writeln(_pending);
    }
    _pending = null;
    _softBreak = false;
    _quotedPrintable = false;
  }

  _ParsedCard finish() {
    _flush();
    final contact = _parse(_text.toString());
    if (contact == null) return (contact: null, photo: null, photoError: false);
    if (_photos.isEmpty) {
      return (contact: contact, photo: null, photoError: false);
    }
    final photo = _parse(_photos.toString())?.photo?.fullSize;
    return (contact: contact, photo: photo, photoError: photo == null);
  }

  fc.Contact? _parse(String fields) {
    try {
      final parsed = fc.FlutterContacts.vCard.import(
        'BEGIN:VCARD\n${fields}END:VCARD\n',
      );
      return parsed.isEmpty ? null : parsed.first;
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }
}
