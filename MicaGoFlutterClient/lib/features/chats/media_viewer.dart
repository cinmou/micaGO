import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/l10n/app_localizations.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/media_cache.dart';
import 'attachment_views.dart';
import 'models/message_model.dart';

/// Full-screen media viewer (Part H): dim background, pinch-zoom, swipe between
/// multiple images, loading + error states. Bytes are fetched via the API
/// client (token travels in the Authorization header, never in a URL or log).
class MediaGalleryViewer extends StatefulWidget {
  final ApiClient api;
  final List<AttachmentModel> images;
  final int initialIndex;

  const MediaGalleryViewer({
    super.key,
    required this.api,
    required this.images,
    this.initialIndex = 0,
  });

  static Future<void> open(
    BuildContext context, {
    required ApiClient api,
    required List<AttachmentModel> images,
    int initialIndex = 0,
  }) {
    return Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black,
        transitionDuration: const Duration(milliseconds: 220),
        reverseTransitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, _, _) => MediaGalleryViewer(
          api: api,
          images: images,
          initialIndex: initialIndex,
        ),
        transitionsBuilder: (_, animation, _, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  @override
  State<MediaGalleryViewer> createState() => _MediaGalleryViewerState();
}

class _MediaGalleryViewerState extends State<MediaGalleryViewer> {
  late final PageController _page = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;
  bool _imageZoomed = false;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final multi = widget.images.length > 1;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _page,
            physics: _imageZoomed
                ? const NeverScrollableScrollPhysics()
                : const PageScrollPhysics(parent: ClampingScrollPhysics()),
            itemCount: widget.images.length,
            onPageChanged: (i) => setState(() {
              _index = i;
              _imageZoomed = false;
            }),
            itemBuilder: (context, i) => _ZoomableImage(
              api: widget.api,
              attachment: widget.images[i],
              onZoomChanged: (zoomed) {
                if (_imageZoomed == zoomed || !mounted) return;
                setState(() => _imageZoomed = zoomed);
              },
            ),
          ),
          // Top bar: close + counter, over a subtle gradient for legibility.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black54, Colors.transparent],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    // C24: show the current file's name in the viewer.
                    Expanded(
                      child: Text(
                        widget.images[_index].displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    if (multi)
                      Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: Text(
                          '${_index + 1} / ${widget.images.length}',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ZoomableImage extends StatefulWidget {
  final ApiClient api;
  final AttachmentModel attachment;
  final ValueChanged<bool>? onZoomChanged;
  const _ZoomableImage({
    required this.api,
    required this.attachment,
    this.onZoomChanged,
  });

  @override
  State<_ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<_ZoomableImage>
    with SingleTickerProviderStateMixin {
  late Future<Uint8List> _future = _load();
  bool _usingCompatibilityPreview = false;
  final TransformationController _tc = TransformationController();
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  Animation<Matrix4>? _zoomAnim;
  TapDownDetails? _doubleTapDetails;
  bool _reportedZoomed = false;

  @override
  void initState() {
    super.initState();
    _anim.addListener(() {
      if (_zoomAnim != null) _tc.value = _zoomAnim!.value;
    });
    _tc.addListener(_onTransformChanged);
  }

  @override
  void dispose() {
    _tc.removeListener(_onTransformChanged);
    _anim.dispose();
    _tc.dispose();
    super.dispose();
  }

  void _onTransformChanged() {
    final zoomed = _tc.value.getMaxScaleOnAxis() > 1.02;
    if (zoomed == _reportedZoomed) return;
    _reportedZoomed = zoomed;
    widget.onZoomChanged?.call(zoomed);
  }

  Future<Uint8List> _load() =>
      MediaCache.instance.attachmentFull(widget.api, widget.attachment.guid);

  void _useCompatibilityPreview() {
    if (_usingCompatibilityPreview) return;
    _usingCompatibilityPreview = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _future = MediaCache.instance.attachmentDisplay(
          widget.api,
          widget.attachment,
        );
      });
    });
  }

  // Double-tap toggles between fit and a 2.5x zoom centered on the tap point,
  // animated — the mature gallery behavior.
  void _handleDoubleTap() {
    final zoomedIn = _tc.value.getMaxScaleOnAxis() > 1.01;
    final Matrix4 target;
    if (zoomedIn) {
      target = Matrix4.identity();
    } else {
      final pos = _doubleTapDetails?.localPosition ?? Offset.zero;
      const scale = 2.5;
      // Scale on the diagonal + translate in the last column (avoids the
      // deprecated Matrix4.translate/scale helpers).
      target = Matrix4.identity()
        ..setEntry(0, 0, scale)
        ..setEntry(1, 1, scale)
        ..setEntry(0, 3, -pos.dx * (scale - 1))
        ..setEntry(1, 3, -pos.dy * (scale - 1));
    }
    _zoomAnim = Matrix4Tween(
      begin: _tc.value,
      end: target,
    ).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOut));
    _anim.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.white),
          );
        }
        if (snap.hasError || snap.data == null) {
          return _ErrorBody(
            name: widget.attachment.displayName,
            onRetry: () => setState(() => _future = _load()),
          );
        }
        return GestureDetector(
          onDoubleTapDown: (d) => _doubleTapDetails = d,
          onDoubleTap: _handleDoubleTap,
          onLongPress: () => showAttachmentActions(
            context,
            api: widget.api,
            attachment: widget.attachment,
          ),
          child: InteractiveViewer(
            transformationController: _tc,
            minScale: 1,
            maxScale: 6,
            child: Center(
              child: Image.memory(
                snap.data!,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) {
                  if (!_usingCompatibilityPreview) {
                    _useCompatibilityPreview();
                    return const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    );
                  }
                  return _ErrorBody(
                    name: widget.attachment.displayName,
                    onRetry: () => setState(() {
                      _usingCompatibilityPreview = false;
                      _future = _load();
                    }),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ErrorBody extends StatelessWidget {
  final String name;
  final VoidCallback onRetry;
  const _ErrorBody({required this.name, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.broken_image_outlined,
            color: Colors.white70,
            size: 48,
          ),
          const SizedBox(height: 12),
          Text(
            name,
            style: const TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: Text(MicaLocalizations.of(context).t('common.retry')),
          ),
        ],
      ),
    );
  }
}

/// C24: full-screen video player for a single video attachment. The stream is
/// fetched with the bearer token in the Authorization header (never in the URL).
/// Failures show a graceful error state — never a blank/broken viewer.
class FullscreenVideo extends StatefulWidget {
  final ApiClient api;
  final AttachmentModel attachment;
  const FullscreenVideo({
    super.key,
    required this.api,
    required this.attachment,
  });

  static Future<void> open(
    BuildContext context, {
    required ApiClient api,
    required AttachmentModel attachment,
  }) {
    return Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (_, _, _) =>
            FullscreenVideo(api: api, attachment: attachment),
      ),
    );
  }

  @override
  State<FullscreenVideo> createState() => _FullscreenVideoState();
}

class _FullscreenVideoState extends State<FullscreenVideo> {
  VideoPlayerController? _controller;
  bool _failed = false;
  bool _controlsVisible = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      // C63: play from the persistent media cache when this video was already
      // downloaded (or sent from this device); otherwise stream from the
      // server and cache the file in the background for next time.
      final guid = widget.attachment.guid;
      final mediaKey = MediaCache.fullMediaKey(guid);
      final cachedFile = await MediaCache.instance.cachedMediaFile(mediaKey);
      final VideoPlayerController controller;
      if (cachedFile != null) {
        controller = VideoPlayerController.file(cachedFile);
      } else {
        controller = VideoPlayerController.networkUrl(
          Uri.parse(widget.api.attachmentUrl(guid)),
          httpHeaders: widget.api.mediaAuthHeaders,
        );
        // Cap the background download so a huge video doesn't double its own
        // bandwidth cost; anything below the cap becomes instantly replayable.
        if (widget.attachment.totalBytes < 200 * 1024 * 1024) {
          unawaited(
            MediaCache.instance.cacheToDiskInBackground(
              mediaKey,
              () => widget.api.getAttachmentBytes(guid),
            ),
          );
        }
      }
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      controller.addListener(_onTick);
      await controller.play();
      setState(() => _controller = controller);
      _scheduleHide();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _onTick() {
    if (mounted) setState(() {}); // refresh position/labels + play state
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  // Auto-hide the controls a few seconds after they appear while playing.
  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && (_controller?.value.isPlaying ?? false)) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null) return;
    final ended = c.value.position >= c.value.duration;
    setState(() {
      if (c.value.isPlaying) {
        c.pause();
        _controlsVisible = true; // keep controls visible while paused
      } else {
        if (ended) c.seekTo(Duration.zero);
        c.play();
        _scheduleHide();
      }
    });
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ended =
        controller != null &&
        controller.value.position >= controller.value.duration &&
        controller.value.duration > Duration.zero;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _failed ? null : _toggleControls,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          children: [
            Center(
              child: _failed
                  ? _ErrorBody(
                      name: widget.attachment.displayName,
                      onRetry: () {
                        setState(() => _failed = false);
                        _init();
                      },
                    )
                  : controller == null
                  ? const CircularProgressIndicator(color: Colors.white)
                  : AspectRatio(
                      aspectRatio: controller.value.aspectRatio == 0
                          ? 16 / 9
                          : controller.value.aspectRatio,
                      child: VideoPlayer(controller),
                    ),
            ),
            // Center play / pause / replay button.
            if (controller != null && !_failed && _controlsVisible)
              Center(
                child: IconButton(
                  iconSize: 64,
                  icon: Icon(
                    ended
                        ? Icons.replay_circle_filled
                        : controller.value.isPlaying
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_filled,
                    color: Colors.white,
                  ),
                  onPressed: _togglePlay,
                ),
              ),
            // Bottom scrubber + time labels.
            if (controller != null && !_failed && _controlsVisible)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black54, Colors.transparent],
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: Row(
                        children: [
                          Text(
                            _fmt(controller.value.position),
                            style: const TextStyle(color: Colors.white),
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              child: VideoProgressIndicator(
                                controller,
                                allowScrubbing: true,
                                colors: VideoProgressColors(
                                  playedColor: Colors.white,
                                  bufferedColor: Colors.white38,
                                  backgroundColor: Colors.white24,
                                ),
                              ),
                            ),
                          ),
                          Text(
                            _fmt(controller.value.duration),
                            style: const TextStyle(color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (_controlsVisible)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black54, Colors.transparent],
                    ),
                  ),
                  child: SafeArea(
                    bottom: false,
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        Expanded(
                          child: Text(
                            widget.attachment.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
