import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../contacts/contacts_service.dart';

/// A deterministic, colored contact avatar: a group icon for groups, otherwise
/// initials derived from the title on a stable per-contact color.
///
/// When [photo] bytes are supplied (a local contact thumbnail), the photo is
/// shown instead. Photos are loaded lazily/by-id (see [HandleAvatar]) —
/// `flutter_contacts` can't bulk-fetch thumbnails cheaply, so we never bulk
/// load; the initials remain the performant fallback.
class ContactAvatar extends StatelessWidget {
  final String title;
  final bool isGroup;
  final double radius;
  final Uint8List? photo;

  const ContactAvatar({
    super.key,
    required this.title,
    this.isGroup = false,
    this.radius = 20,
    this.photo,
  });

  @override
  Widget build(BuildContext context) {
    final base = _colorFor(title);
    final bg = base.withValues(alpha: 0.22);
    final fg = HSLColor.fromColor(base).withLightness(0.35).toColor();
    if (photo != null && photo!.isNotEmpty) {
      return CircleAvatar(radius: radius, backgroundImage: MemoryImage(photo!));
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: bg,
      foregroundColor: fg,
      child: isGroup
          ? Icon(Icons.group, size: radius)
          : Text(
              _initials(title),
              style: TextStyle(
                fontSize: radius * 0.7,
                fontWeight: FontWeight.w600,
              ),
            ),
    );
  }

  static String _initials(String title) {
    final source = title.trim();
    if (source.isEmpty) return '#';
    if (RegExp(r'^[+\d][\d\s()\-]*$').hasMatch(source)) return '#';
    final words = source
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '#';
    String first(String w) =>
        w.isEmpty ? '' : String.fromCharCode(w.runes.first).toUpperCase();
    if (words.length == 1) return first(words.first);
    return first(words[0]) + first(words[1]);
  }

  /// Stable color from the title, chosen from a small Material palette.
  static Color _colorFor(String s) {
    const palette = [
      Color(0xFF3949AB), // indigo
      Color(0xFF00897B), // teal
      Color(0xFF6D4C41), // brown
      Color(0xFFD81B60), // pink
      Color(0xFF1E88E5), // blue
      Color(0xFF43A047), // green
      Color(0xFFF4511E), // deep orange
      Color(0xFF8E24AA), // purple
    ];
    var hash = 0;
    for (final c in s.codeUnits) {
      hash = (hash * 31 + c) & 0x7fffffff;
    }
    return palette[hash % palette.length];
  }
}

/// A [ContactAvatar] that lazily loads the matched contact's local thumbnail
/// for [handle] (cached in memory by [ContactsService]). Falls back to initials
/// while loading or when there is no photo / no match. For 1:1 chats only;
/// groups always show the group glyph.
class HandleAvatar extends StatelessWidget {
  final String title;
  final String? handle;
  final List<String> participantHandles;
  final bool isGroup;
  final double radius;
  final String? localAvatarPath;
  final String? assetAvatarPath;

  const HandleAvatar({
    super.key,
    required this.title,
    required this.handle,
    this.participantHandles = const [],
    this.isGroup = false,
    this.radius = 20,
    this.localAvatarPath,
    this.assetAvatarPath,
  });

  @override
  Widget build(BuildContext context) {
    final override = localAvatarPath?.trim() ?? '';
    if (override.isNotEmpty) {
      final file = File(override);
      if (file.existsSync()) {
        return CircleAvatar(radius: radius, backgroundImage: FileImage(file));
      }
    }
    final asset = assetAvatarPath?.trim() ?? '';
    if (asset.isNotEmpty) {
      return CircleAvatar(radius: radius, backgroundImage: AssetImage(asset));
    }
    final fallback = ContactAvatar(
      title: title,
      isGroup: isGroup,
      radius: radius,
    );
    final contacts = context.watch<ContactsService>();
    if (isGroup) {
      final handles = participantHandles
          .map((h) => h.trim())
          .where((h) => h.isNotEmpty)
          .toList(growable: false);
      if (handles.length < 2 || !contacts.isReady) return fallback;
      return FutureBuilder<List<_GroupAvatarEntry>>(
        future: _loadGroupEntries(contacts, handles),
        builder: (context, snap) {
          final entries =
              snap.data ??
              [for (final h in handles.take(4)) _GroupAvatarEntry(handle: h)];
          return _GroupAvatar(
            title: title,
            entries: entries,
            totalCount: handles.length,
            radius: radius,
          );
        },
      );
    }
    if (handle == null || handle!.isEmpty) return fallback;
    if (!contacts.isReady) return fallback;
    return FutureBuilder<Uint8List?>(
      future: contacts.thumbnailForHandle(handle),
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes == null || bytes.isEmpty) return fallback;
        return ContactAvatar(
          title: title,
          isGroup: isGroup,
          radius: radius,
          photo: bytes,
        );
      },
    );
  }

  Future<List<_GroupAvatarEntry>> _loadGroupEntries(
    ContactsService contacts,
    List<String> handles,
  ) async {
    final entries = <_GroupAvatarEntry>[];
    for (final handle in handles.take(6)) {
      entries.add(
        _GroupAvatarEntry(
          handle: handle,
          photo: await contacts.thumbnailForHandle(handle),
        ),
      );
    }
    entries.sort((a, b) {
      final aPhoto = a.photo != null && a.photo!.isNotEmpty;
      final bPhoto = b.photo != null && b.photo!.isNotEmpty;
      if (aPhoto == bPhoto) return 0;
      return aPhoto ? -1 : 1;
    });
    return entries.take(4).toList(growable: false);
  }
}

class _GroupAvatarEntry {
  final String handle;
  final Uint8List? photo;
  const _GroupAvatarEntry({required this.handle, this.photo});
}

class _GroupAvatar extends StatelessWidget {
  final String title;
  final List<_GroupAvatarEntry> entries;
  final int totalCount;
  final double radius;

  const _GroupAvatar({
    required this.title,
    required this.entries,
    required this.totalCount,
    required this.radius,
  });

  @override
  Widget build(BuildContext context) {
    final size = radius * 2;
    final childRadius = radius * 0.58;
    final visible = entries.take(4).toList(growable: false);
    if (visible.length < 2) {
      return ContactAvatar(title: title, isGroup: true, radius: radius);
    }
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < visible.length; i++)
            Positioned(
              left: _offset(i, visible.length, size).dx,
              top: _offset(i, visible.length, size).dy,
              child: _MiniAvatar(
                entry: visible[i],
                radius: childRadius,
                showOverflow:
                    totalCount > visible.length && i == visible.length - 1,
              ),
            ),
        ],
      ),
    );
  }

  Offset _offset(int index, int count, double size) {
    final small = radius * 1.16;
    if (count == 2) {
      return index == 0 ? Offset(0, 0) : Offset(size - small, size - small);
    }
    if (count == 3) {
      return [
        Offset((size - small) / 2, 0),
        Offset(0, size - small),
        Offset(size - small, size - small),
      ][index];
    }
    return [
      Offset(0, 0),
      Offset(size - small, 0),
      Offset(0, size - small),
      Offset(size - small, size - small),
    ][index];
  }
}

class _MiniAvatar extends StatelessWidget {
  final _GroupAvatarEntry entry;
  final double radius;
  final bool showOverflow;

  const _MiniAvatar({
    required this.entry,
    required this.radius,
    required this.showOverflow,
  });

  @override
  Widget build(BuildContext context) {
    final avatar = ContactAvatar(
      title: entry.handle,
      radius: radius,
      photo: entry.photo,
    );
    if (!showOverflow) return avatar;
    return CircleAvatar(
      radius: radius,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
      child: Icon(Icons.group, size: radius),
    );
  }
}
