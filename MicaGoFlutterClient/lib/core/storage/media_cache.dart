import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../../features/chats/models/message_model.dart';
import '../network/api_client.dart';

/// C63: persistent media cache.
///
/// Attachment bytes used to live only in a 48 MB in-memory LRU — every app
/// restart refetched every photo/preview from the server. This adds a
/// **permanent disk layer** under the same keys (app-support/media_cache, so
/// Android doesn't purge it like a temp dir; it is only removed with the app's
/// data): reads go memory → disk → network, and every network fetch is written
/// through to disk. Sent attachments are [seed]ed directly, so the client
/// never re-downloads a file it just uploaded.
///
/// Keys are the same strings call sites always used (`previewUrl ?? guid`,
/// plus a `full:` prefix for original bytes), encoded to safe filenames with
/// URL-safe base64.
class MediaCache {
  MediaCache._();
  static final MediaCache instance = MediaCache._();

  Directory? _dir;
  final Map<String, Future<Uint8List>> _inflight = {};

  /// C66: bytes for *pending local sends* (`local-<tempId>` attachment guids),
  /// pinned outside the evictable LRU. A pending bubble must always hit
  /// synchronously — falling through to the FutureBuilder meant a spinner (and
  /// a doomed network fetch for a guid the server has never heard of).
  final Map<String, Uint8List> _pinned = {};

  void pinLocal(String key, Uint8List bytes) {
    if (key.isEmpty || bytes.isEmpty) return;
    _pinned[key] = bytes;
  }

  void unpinLocal(String key) {
    _pinned.remove(key);
  }

  /// Resolves the cache directory once (called from AppController.bootstrap).
  /// Until this completes the cache transparently degrades to memory+network —
  /// no per-load platform-channel hop, and unit/widget tests (no path_provider)
  /// keep the old behavior.
  Future<void> init() async {
    if (_dir != null) return;
    try {
      final support = await getApplicationSupportDirectory();
      final root = Directory('${support.path}/media_cache');
      // C70: v2 — earlier builds could seed a *wrong* local image under a
      // server key (multi-image sends), permanently caching swapped photos.
      // Cached media is server-authoritative now; discard the v1 store once.
      final dir = Directory('${root.path}/v2');
      await dir.create(recursive: true);
      _dir = dir;
      unawaited(_purgeLegacyV1(root));
    } catch (_) {
      // No disk layer this session; everything still works from memory+network.
    }
  }

  /// One-time cleanup of pre-v2 cache files sitting in the media_cache root.
  Future<void> _purgeLegacyV1(Directory root) async {
    try {
      await for (final entry in root.list()) {
        if (entry is File) {
          try {
            await entry.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  File? _fileFor(String key) {
    final dir = _dir;
    if (dir == null) return null;
    return File('${dir.path}/${fileNameForMediaKey(key)}');
  }

  /// Memory-only synchronous hit (used by tiles to render without a spinner
  /// frame while scrolling, C51). Disk hits arrive through [load].
  Uint8List? memoryHit(String key) => _pinned[key] ?? _memoryCache[key];

  /// memory → disk → [fetch] (network), writing through to both layers.
  /// Concurrent loads of the same key share one future.
  Future<Uint8List> load(String key, Future<Uint8List> Function() fetch) {
    final pinned = _pinned[key];
    if (pinned != null) return Future.value(pinned);
    final mem = _memoryCache[key];
    if (mem != null) return Future.value(mem);
    final running = _inflight[key];
    if (running != null) return running;
    final future = _loadInner(key, fetch);
    _inflight[key] = future;
    future.whenComplete(() => _inflight.remove(key)).ignore();
    return future;
  }

  Future<Uint8List> _loadInner(
    String key,
    Future<Uint8List> Function() fetch,
  ) async {
    final file = _fileFor(key);
    if (file != null) {
      try {
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          if (bytes.isNotEmpty) {
            _memoryCache[key] = bytes;
            return bytes;
          }
        }
      } catch (_) {
        // Disk problems fall through to the network.
      }
    }
    final bytes = await fetch();
    _memoryCache[key] = bytes;
    unawaited(_writeDisk(key, bytes));
    return bytes;
  }

  /// The on-disk file for [key], or null when not cached. Used for media that
  /// plays from a file path (video) rather than from bytes in memory.
  Future<File?> cachedMediaFile(String key) async {
    final file = _fileFor(key);
    if (file == null) return null;
    try {
      if (await file.exists() && (await file.length()) > 0) return file;
    } catch (_) {}
    return null;
  }

  /// Downloads [key] to disk in the background when absent (e.g. caching a
  /// video during its first streamed playback). Never throws.
  Future<void> cacheToDiskInBackground(
    String key,
    Future<Uint8List> Function() fetch,
  ) async {
    try {
      if (await cachedMediaFile(key) != null) return;
      final bytes = await fetch();
      if (bytes.isNotEmpty) await _writeDisk(key, bytes);
    } catch (_) {
      // Best-effort; the next playback streams again.
    }
  }

  // --- attachment-shaped helpers (the two fetch paths the app uses) ---------

  /// Preview/inline bytes: same key shape call sites always used.
  Future<Uint8List> attachmentPreview(ApiClient api, AttachmentModel a) =>
      load(a.previewUrl ?? a.guid, () => api.getAttachmentPreviewBytes(a));

  /// Original attachment bytes (save/share/forward/video).
  Future<Uint8List> attachmentFull(ApiClient api, String guid) =>
      load(fullMediaKey(guid), () => api.getAttachmentBytes(guid));

  static String fullMediaKey(String attachmentGuid) => 'full:$attachmentGuid';

  Future<void> _writeDisk(String key, Uint8List bytes) async {
    final file = _fileFor(key);
    if (file == null) return;
    try {
      // Write via a temp name so a crash mid-write never leaves a truncated
      // file that would be served as a "cached" image.
      final tmp = File('${file.path}.part');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // Cache write failures are non-fatal.
    }
  }

}

/// Pure: cache-key → safe filename (URL-safe base64, no padding). Collision-free
/// and reversible; keys are short (guids / server paths).
String fileNameForMediaKey(String key) =>
    base64UrlEncode(utf8.encode(key)).replaceAll('=', '');

/// The in-memory hot layer over the disk cache (thread bubbles + viewer).
///
/// Bounded LRU by total bytes (C51): an unbounded map kept the raw encoded bytes
/// of every image ever scrolled past — on top of Flutter's own decoded-image
/// cache — so a thread with many photos grew memory without limit and the
/// resulting GC pressure showed up as scroll jank. Capped + least-recently-used
/// eviction keeps the working set hot while bounding total memory. Callers go
/// through [MediaCache] (`memoryHit`/`load`/`seed`) — this is an implementation
/// detail (was the public `imageByteCache` in media_viewer.dart before C63).
final _memoryCache = LruByteCache();

class LruByteCache {
  LruByteCache({this.maxBytes = 48 * 1024 * 1024});

  final int maxBytes;
  // Insertion order is the LRU order: a get re-inserts at the end (most recent).
  final _entries = <String, Uint8List>{};
  int _bytes = 0;

  Uint8List? operator [](String key) {
    final value = _entries.remove(key);
    if (value != null) _entries[key] = value; // mark most-recently-used
    return value;
  }

  void operator []=(String key, Uint8List value) {
    final previous = _entries.remove(key);
    if (previous != null) _bytes -= previous.length;
    _entries[key] = value;
    _bytes += value.length;
    while (_bytes > maxBytes && _entries.isNotEmpty) {
      final oldest = _entries.keys.first;
      final removed = _entries.remove(oldest);
      if (removed != null) _bytes -= removed.length;
    }
  }

  void clear() {
    _entries.clear();
    _bytes = 0;
  }
}
