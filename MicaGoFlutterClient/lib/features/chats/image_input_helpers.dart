import 'dart:typed_data';
import 'dart:ui' as ui;

/// Matches the Go server's single-attachment limit (`maxOutgoingAttachmentBytes`).
const int maxOutgoingAttachmentBytes = 100 * 1024 * 1024;

/// Reads only the encoded image header to compute width / height without
/// decoding full bitmap pixels. Returns `null` for non-images or invalid data.
Future<double?> probeImageAspectRatio({Uint8List? bytes, String? path}) async {
  ui.ImmutableBuffer? buffer;
  try {
    if (bytes != null && bytes.isNotEmpty) {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    } else if (path != null && path.isNotEmpty) {
      buffer = await ui.ImmutableBuffer.fromFilePath(path);
    } else {
      return null;
    }
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      if (descriptor.width <= 0 || descriptor.height <= 0) return null;
      final ratio = descriptor.width / descriptor.height;
      return ratio.isFinite && ratio > 0 ? ratio : null;
    } finally {
      descriptor.dispose();
    }
  } catch (_) {
    return null;
  } finally {
    buffer?.dispose();
  }
}

/// Formats a byte count compactly for attachment staging badges (e.g. `2.4 MB`).
String formatCompactBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// Detects common raster image formats from file header magic bytes so pasted
/// or content-URI images never rely solely on filename extensions or hardcoded
/// `image/png` labels.
String? detectImageMimeType(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0D &&
      bytes[5] == 0x0A &&
      bytes[6] == 0x1A &&
      bytes[7] == 0x0A) {
    return 'image/png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38 &&
      (bytes[4] == 0x37 || bytes[4] == 0x39) &&
      bytes[5] == 0x61) {
    return 'image/gif';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
    return 'image/bmp';
  }
  if (bytes.length >= 4 &&
      ((bytes[0] == 0x49 &&
              bytes[1] == 0x49 &&
              bytes[2] == 0x2A &&
              bytes[3] == 0x00) ||
          (bytes[0] == 0x4D &&
              bytes[1] == 0x4D &&
              bytes[2] == 0x00 &&
              bytes[3] == 0x2A))) {
    return 'image/tiff';
  }
  if (bytes.length >= 12 &&
      bytes[4] == 0x66 &&
      bytes[5] == 0x74 &&
      bytes[6] == 0x79 &&
      bytes[7] == 0x70) {
    final brand = String.fromCharCodes(bytes.sublist(8, 12));
    if (brand == 'heic' ||
        brand == 'heix' ||
        brand == 'hevc' ||
        brand == 'hevx') {
      return 'image/heic';
    }
    if (brand == 'mif1' || brand == 'msf1' || brand == 'heif') {
      return 'image/heif';
    }
  }
  return null;
}

/// Canonical filename extension for a MIME type (defaults to `.png`).
String extensionForImageMime(String mimeType) {
  switch (mimeType.trim().toLowerCase()) {
    case 'image/gif':
      return '.gif';
    case 'image/jpeg':
    case 'image/jpg':
      return '.jpg';
    case 'image/bmp':
      return '.bmp';
    case 'image/tiff':
      return '.tiff';
    case 'image/webp':
      return '.webp';
    case 'image/heic':
      return '.heic';
    case 'image/heif':
      return '.heif';
    default:
      return '.png';
  }
}

/// Parses Linux `text/uri-list` or `x-special/gnome-copied-files` clipboard text
/// into local filesystem paths.
List<String> parseLinuxClipboardUriList(String raw) {
  final paths = <String>[];
  for (final rawLine in raw.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty ||
        line.startsWith('#') ||
        line == 'copy' ||
        line == 'cut') {
      continue;
    }
    final uri = Uri.tryParse(line);
    if (uri != null && uri.scheme == 'file') {
      try {
        paths.add(uri.toFilePath());
      } catch (_) {}
    } else if (line.startsWith('/')) {
      paths.add(line);
    }
  }
  return paths;
}
