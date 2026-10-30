import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../../features/chats/models/message_model.dart';
import '../network/api_client.dart';

/// Memory → disk → network, with separate thumbnail/display/original keys.
/// Pending local sends remain pinned outside the evictable caches.
class MediaCache {
  MediaCache({
    this.maxDiskBytes = 256 * 1024 * 1024,
    this.maxDiskAge = const Duration(days: 30),
    int maxMemoryBytes = 48 * 1024 * 1024,
  }) : _memoryCache = LruByteCache(maxBytes: maxMemoryBytes);
  static final MediaCache instance = MediaCache();
  final int maxDiskBytes;
  final Duration maxDiskAge;
  final LruByteCache _memoryCache;
  Future<void> _diskSerial = Future.value();

  bool accessAllowed = true;
  Directory? _dir;
  final Map<String, Future<Uint8List>> _inflight = {};

  /// Visible media can jump ahead of queued background downloads.
  static const int _maxConcurrentFetches = 4;
  int _activeFetches = 0;
  final List<Completer<void>> _fetchQueue = [];

  Future<void> _acquireFetchSlot({bool urgent = false}) {
    if (_activeFetches < _maxConcurrentFetches) {
      _activeFetches++;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    if (urgent) {
      _fetchQueue.insert(0, waiter);
    } else {
      _fetchQueue.add(waiter);
    }
    return waiter.future;
  }

  void _releaseFetchSlot() {
    if (_fetchQueue.isNotEmpty) {
      _fetchQueue.removeAt(0).complete();
      return;
    }
    if (_activeFetches > 0) _activeFetches--;
  }

  /// Reserve the last decoded image ratio while its bytes load.
  final Map<String, double> _aspectRatios = {};

  double? aspectRatioFor(String key) => _aspectRatios[key];

  void rememberAspectRatio(String key, double ratio) {
    if (key.isEmpty || !ratio.isFinite || ratio <= 0) return;
    _aspectRatios[key] = ratio;
  }

  /// Pending sends must remain available before server attachment IDs exist.
  final Map<String, Uint8List> _pinned = {};
  final Map<String, Future<Uint8List> Function()> _localPreviews = {};
  final Map<String, Future<Uint8List> Function()> _localOriginals = {};

  void registerLocal(
    String key, {
    Uint8List? preview,
    required Future<Uint8List> Function() loadPreview,
    required Future<Uint8List> Function() loadOriginal,
  }) {
    if (preview != null) pinLocal(key, preview);
    _localPreviews[key] = loadPreview;
    _localOriginals[key] = loadOriginal;
  }

  void pinLocal(String key, Uint8List bytes) {
    if (key.isEmpty || bytes.isEmpty) return;
    _pinned[key] = bytes;
  }

  void unpinLocal(String key) {
    _pinned.remove(key);
    _localPreviews.remove(key);
    _localOriginals.remove(key);
  }

  /// [directory] overrides the platform cache directory for isolated storage.
  Future<void> init({Directory? directory}) async {
    if (_dir != null) return;
    try {
      if (directory == null) {
        final support = await getApplicationSupportDirectory();
        final root = Directory('${support.path}/media_cache');
        directory = Directory('${root.path}/v2');
        unawaited(_purgeLegacyV1(root));
      }
      await directory.create(recursive: true);
      _dir = directory;
      await prune();
    } catch (_) {
      // Disk caching is optional; network and memory remain usable.
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
  Uint8List? memoryHit(String key) =>
      accessAllowed ? (_pinned[key] ?? _memoryCache[key]) : null;

  /// memory → disk → [fetch] (network), writing through to both layers.
  /// Concurrent loads of the same key share one future.
  Future<Uint8List> load(
    String key,
    Future<Uint8List> Function() fetch, {
    bool urgent = false,
  }) {
    if (!accessAllowed) {
      return Future.error(
        const ApiException(
          code: 'unauthorized',
          message: 'Device access rejected.',
          statusCode: 401,
        ),
      );
    }
    final pinned = _pinned[key];
    if (pinned != null) return Future.value(pinned);
    final mem = _memoryCache[key];
    if (mem != null) return Future.value(mem);
    final running = _inflight[key];
    if (running != null) return running;
    final local = _localPreviews[key];
    final future =
        (local == null
                ? _loadInner(key, fetch, urgent: urgent)
                : local().then((bytes) {
                    if (identical(_localPreviews[key], local)) {
                      _pinned[key] = bytes;
                    }
                    return bytes;
                  }))
            .then((bytes) {
              if (!accessAllowed) {
                throw const ApiException(
                  code: 'unauthorized',
                  message: 'Device access rejected.',
                  statusCode: 401,
                );
              }
              return bytes;
            });
    _inflight[key] = future;
    future.whenComplete(() => _inflight.remove(key)).ignore();
    return future;
  }

  Future<Uint8List> _loadInner(
    String key,
    Future<Uint8List> Function() fetch, {
    required bool urgent,
  }) async {
    final cached = _dir == null
        ? null
        : await _disk(() async {
            final file = _fileFor(key);
            if (file == null || !await file.exists()) return null;
            final stat = await file.stat();
            if (DateTime.now().difference(stat.modified) > maxDiskAge) {
              await file.delete();
              return null;
            }
            final bytes = await file.readAsBytes();
            if (bytes.isEmpty) return null;
            await file.setLastModified(DateTime.now());
            return bytes;
          }, null);
    if (cached != null) {
      _memoryCache[key] = cached;
      return cached;
    }
    await _acquireFetchSlot(urgent: urgent);
    final Uint8List bytes;
    try {
      bytes = await fetch();
    } finally {
      _releaseFetchSlot();
    }
    _memoryCache[key] = bytes;
    unawaited(_writeDisk(key, bytes));
    return bytes;
  }

  /// Bounded bytes used by message rows and media grids.
  Future<Uint8List> attachmentPreview(ApiClient api, AttachmentModel a) =>
      load(previewMediaKey(a), () {
        // The bounded server preview is a PNG, which freezes GIFs on their
        // first frame. Keep the original encoded GIF so Flutter's built-in
        // multi-frame image codec can animate it directly in the timeline.
        if (a.isAnimatedGif && !a.guid.startsWith('local-')) {
          return api.getAttachmentBytes(a.guid);
        }
        if (a.isStickerLike || a.guid.startsWith('local-')) {
          return api.getAttachmentPreviewBytes(a);
        }
        return api.getAttachmentThumbnailBytes(a);
      });

  /// High-quality display bytes used only after opening the media viewer.
  Future<Uint8List> attachmentDisplay(ApiClient api, AttachmentModel a) =>
      a.guid.startsWith('local-')
      ? attachmentFull(api, a.guid)
      : load(
          displayMediaKey(a),
          () => a.isAnimatedGif
              ? api.getAttachmentBytes(a.guid)
              : api.getAttachmentPreviewBytes(a),
          urgent: true,
        );

  /// Original attachment bytes (save/share/forward/video).
  Future<Uint8List> attachmentFull(ApiClient api, String guid) {
    if (guid.startsWith('local-')) {
      final original = _localOriginals[guid];
      if (original != null) return original();
      final bytes = _pinned[guid];
      if (bytes != null) return Future.value(bytes);
      return Future.error(
        StateError('Local attachment is no longer available'),
      );
    }
    return load(
      fullMediaKey(guid),
      () => api.getAttachmentBytes(guid),
      urgent: true,
    );
  }

  static String fullMediaKey(String attachmentGuid) => 'full:$attachmentGuid';

  static String previewMediaKey(AttachmentModel attachment) {
    if (attachment.guid.startsWith('local-')) return attachment.guid;
    if (attachment.isAnimatedGif) return 'gif:v1:${attachment.guid}';
    if (attachment.isStickerLike) {
      return 'sticker:v1:${attachment.previewUrl ?? attachment.guid}';
    }
    return 'thumb:v1:${attachment.guid}';
  }

  static String displayMediaKey(AttachmentModel attachment) =>
      attachment.isAnimatedGif
      ? previewMediaKey(attachment)
      : 'display:v1:${attachment.previewUrl ?? attachment.guid}';

  Future<T> _disk<T>(Future<T> Function() action, T fallback) {
    final result = _diskSerial.then((_) async {
      try {
        return await action();
      } on FileSystemException {
        return fallback;
      }
    });
    _diskSerial = result.then(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }

  Future<void> _writeDisk(String key, Uint8List bytes) => _disk(() async {
    final file = _fileFor(key);
    if (file == null || bytes.isEmpty || bytes.length > maxDiskBytes) return;
    final tmp = File('${file.path}.part');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
    await _pruneDisk();
  }, null);

  /// Waits for queued disk writes, then removes expired and least-used entries.
  Future<void> prune() => _disk(_pruneDisk, null);

  Future<void> _pruneDisk() async {
    final dir = _dir;
    if (dir == null) return;
    final now = DateTime.now();
    final entries = <({File file, FileStat stat})>[];
    var total = 0;
    await for (final entry in dir.list(followLinks: false)) {
      if (entry is! File) continue;
      final stat = await entry.stat();
      final age = now.difference(stat.modified);
      if (entry.path.endsWith('.part')) {
        if (age > const Duration(hours: 1)) await entry.delete();
        continue;
      }
      if (stat.size == 0 || age > maxDiskAge) {
        await entry.delete();
      } else {
        entries.add((file: entry, stat: stat));
        total += stat.size;
      }
    }
    entries.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
    for (final entry in entries) {
      if (total <= maxDiskBytes) break;
      await entry.file.delete();
      total -= entry.stat.size;
    }
  }
}

/// Pure: cache-key → safe filename (URL-safe base64, no padding). Collision-free
/// and reversible; keys are short (guids / server paths).
String fileNameForMediaKey(String key) =>
    base64UrlEncode(utf8.encode(key)).replaceAll('=', '');

/// Insertion-ordered LRU, bounded by encoded byte size.
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
