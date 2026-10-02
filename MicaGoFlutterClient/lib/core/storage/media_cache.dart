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
/// through to disk.
///
/// Thumbnail, display-preview, and original bytes use distinct versioned keys,
/// encoded to safe filenames with URL-safe base64. This prevents an old inline
/// cache entry containing a full-resolution photo from returning to the feed.
class MediaCache {
  MediaCache._();
  static final MediaCache instance = MediaCache._();

  bool accessAllowed = true;
  Directory? _dir;
  final Map<String, Future<Uint8List>> _inflight = {};

  /// C77: a bounded fetch gate. Every tile used to fire its own request the
  /// moment it scrolled into view, so one 9-photo message opened nine parallel
  /// downloads and a fast scroll queued dozens — starving the ones actually on
  /// screen. Loads past the limit wait instead of piling onto the socket.
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

  /// C77: remembers each attachment's decoded aspect ratio (width / height).
  /// The first view of an image cannot know its shape before the bytes arrive,
  /// but every later view — scrolling back, reopening the thread — can reserve
  /// exactly the right box, so the placeholder no longer resizes into place.
  final Map<String, double> _aspectRatios = {};

  double? aspectRatioFor(String key) => _aspectRatios[key];

  void rememberAspectRatio(String key, double ratio) {
    if (key.isEmpty || !ratio.isFinite || ratio <= 0) return;
    _aspectRatios[key] = ratio;
  }

  /// C66: bytes for *pending local sends* (`local-<tempId>` attachment guids),
  /// pinned outside the evictable LRU. A pending bubble must always hit
  /// synchronously — falling through to the FutureBuilder meant a spinner (and
  /// a doomed network fetch for a guid the server has never heard of).
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

  // --- attachment-shaped helpers (the two fetch paths the app uses) ---------

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
