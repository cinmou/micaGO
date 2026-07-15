import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/l10n/app_localizations.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/media_cache.dart';
import '../../core/ui/top_banner.dart';
import 'media_viewer.dart';
import 'models/message_model.dart';
import 'url_preview.dart';

/// Renders a single attachment in a message bubble, choosing the right view by
/// kind. Display-only — the server has no media-send endpoint (C2 gap).
///
/// [imageSiblings] are all image attachments in the same message; tapping an
/// image opens the full-screen gallery at this image's [imageIndex] so the user
/// can swipe between them.
class AttachmentView extends StatelessWidget {
  final ApiClient api;
  final AttachmentModel attachment;
  final List<AttachmentModel> imageSiblings;
  final int imageIndex;

  /// C64: when set, tile long-presses call this (the thread routes it into the
  /// unified message action menu) instead of the legacy attachment sheet.
  final void Function(Offset globalPosition, AttachmentModel attachment)?
  onLongPress;

  const AttachmentView({
    super.key,
    required this.api,
    required this.attachment,
    this.imageSiblings = const [],
    this.imageIndex = 0,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final overrideAll = onLongPress;
    final override = overrideAll == null
        ? null
        : (Offset position) => overrideAll(position, attachment);
    if (attachment.isOpaquePreviewPayload) {
      return const SizedBox.shrink();
    }
    // C32: stickers (incl. third-party iMessage sticker packs) are handled first
    // and always as a sticker — we try to render the image and, if that fails,
    // show a clean "Sticker" placeholder rather than a broken file/“TIFF” card.
    if (attachment.isStickerLike) {
      return _StickerAttachment(
        api: api,
        attachment: attachment,
        onLongPress: override,
      );
    }
    if (attachment.canRenderInlineImage) {
      return _ImageAttachment(
        api: api,
        attachment: attachment,
        siblings: imageSiblings.isEmpty ? [attachment] : imageSiblings,
        index: imageIndex,
        onLongPress: override,
      );
    }
    if (attachment.isImage && attachment.needsPreviewConversion) {
      return _PreviewUnavailableAttachment(
        api: api,
        attachment: attachment,
        onLongPress: override,
      );
    }
    if (attachment.isAudio) {
      return _AudioAttachment(
        api: api,
        attachment: attachment,
        onLongPress: override,
      );
    }
    if (attachment.isVideo) {
      return _VideoAttachment(
        api: api,
        attachment: attachment,
        onLongPress: override,
      );
    }
    if (attachment.isLocation) {
      return _LocationAttachment(api: api, attachment: attachment);
    }
    if (attachment.isLinkPreview) {
      return _LinkAttachment(attachment: attachment);
    }
    return _FileAttachment(
      api: api,
      attachment: attachment,
      onLongPress: override,
    );
  }
}

enum AttachmentAction { save, share, open }

/// C64: tiles route long-press to the unified message menu when the thread
/// provided an override; standalone contexts (details grid, viewers) keep the
/// legacy sheet.
void _tileLongPress(
  BuildContext context,
  void Function(Offset)? override,
  Offset globalPosition, {
  required ApiClient api,
  required AttachmentModel attachment,
}) {
  if (override != null) {
    override(globalPosition);
    return;
  }
  showAttachmentActions(context, api: api, attachment: attachment);
}

/// C64: runs one attachment action directly (used by the unified message
/// action menu; the legacy [showAttachmentActions] sheet also dispatches here).
Future<void> runAttachmentAction(
  BuildContext context, {
  required ApiClient api,
  required AttachmentModel attachment,
  required AttachmentAction action,
}) async {
  switch (action) {
    case AttachmentAction.save:
      await _saveAttachment(context, api: api, attachment: attachment);
    case AttachmentAction.share:
      await _shareAttachment(context, api: api, attachment: attachment);
    case AttachmentAction.open:
      await _openAttachment(context, api: api, attachment: attachment);
  }
}

Future<void> showAttachmentActions(
  BuildContext context, {
  required ApiClient api,
  required AttachmentModel attachment,
}) async {
  final strings = MicaLocalizations.of(context);
  final action = await showModalBottomSheet<AttachmentAction>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.file_download_outlined),
              title: Text(strings.t('chat.saveAttachment')),
              subtitle: Text(attachment.displayName),
              onTap: () =>
                  Navigator.of(sheetContext).pop(AttachmentAction.save),
            ),
            ListTile(
              leading: const Icon(Icons.ios_share_outlined),
              title: Text(strings.t('chat.shareAttachment')),
              onTap: () =>
                  Navigator.of(sheetContext).pop(AttachmentAction.share),
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new_outlined),
              title: Text(strings.t('chat.openAttachment')),
              onTap: () =>
                  Navigator.of(sheetContext).pop(AttachmentAction.open),
            ),
          ],
        ),
      );
    },
  );
  if (!context.mounted || action == null) return;
  await runAttachmentAction(
    context,
    api: api,
    attachment: attachment,
    action: action,
  );
}

Future<void> _saveAttachment(
  BuildContext context, {
  required ApiClient api,
  required AttachmentModel attachment,
}) async {
  final strings = MicaLocalizations.of(context);
  try {
    TopBanner.show(context, strings.t('chat.savingAttachment'));
    final bytes = await MediaCache.instance.attachmentFull(
      api,
      attachment.guid,
    );
    if (!context.mounted) return;

    final fileName = _attachmentSaveName(attachment);
    String? path;
    try {
      path = await FilePicker.platform.saveFile(
        dialogTitle: strings.t('chat.saveAttachment'),
        fileName: fileName,
        bytes: bytes,
      );
    } on UnsupportedError {
      path = await FilePicker.platform.saveFile(
        dialogTitle: strings.t('chat.saveAttachment'),
        fileName: fileName,
      );
      if (path != null) {
        await File(path).writeAsBytes(bytes, flush: true);
      }
    }
    if (!context.mounted || path == null) return;
    TopBanner.show(context, strings.t('chat.attachmentSaved'));
  } catch (_) {
    if (!context.mounted) return;
    TopBanner.show(
      context,
      strings.t('chat.attachmentSaveFailed'),
      kind: TopBannerKind.error,
    );
  }
}

Future<File> _writeTempAttachment({
  required ApiClient api,
  required AttachmentModel attachment,
}) async {
  final bytes = await MediaCache.instance.attachmentFull(api, attachment.guid);
  final dir = await getTemporaryDirectory();
  final folder = Directory('${dir.path}/micago-attachments');
  if (!await folder.exists()) {
    await folder.create(recursive: true);
  }
  final file = File('${folder.path}/${_attachmentSaveName(attachment)}');
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

Future<void> _shareAttachment(
  BuildContext context, {
  required ApiClient api,
  required AttachmentModel attachment,
}) async {
  final strings = MicaLocalizations.of(context);
  try {
    final file = await _writeTempAttachment(api: api, attachment: attachment);
    if (!context.mounted) return;
    await Share.shareXFiles(
      [XFile(file.path, mimeType: attachment.mimeType)],
      subject: attachment.displayName,
      fileNameOverrides: [_attachmentSaveName(attachment)],
    );
  } catch (_) {
    if (!context.mounted) return;
    TopBanner.show(
      context,
      strings.t('chat.attachmentShareFailed'),
      kind: TopBannerKind.error,
    );
  }
}

Future<void> _openAttachment(
  BuildContext context, {
  required ApiClient api,
  required AttachmentModel attachment,
}) async {
  final strings = MicaLocalizations.of(context);
  try {
    final file = await _writeTempAttachment(api: api, attachment: attachment);
    final result = await OpenFilex.open(file.path, type: attachment.mimeType);
    if (!context.mounted || result.type == ResultType.done) return;
    TopBanner.show(
      context,
      result.message.isNotEmpty
          ? result.message
          : strings.t('chat.attachmentOpenFailed'),
      kind: TopBannerKind.error,
    );
  } catch (_) {
    if (!context.mounted) return;
    TopBanner.show(
      context,
      strings.t('chat.attachmentOpenFailed'),
      kind: TopBannerKind.error,
    );
  }
}

String _attachmentSaveName(AttachmentModel attachment) {
  final display = attachment.displayName.trim();
  var name = display.isEmpty || display == 'Attachment'
      ? 'attachment-${attachment.guid}'
      : display.split(RegExp(r'[/\\]')).last;
  name = name.replaceAll(RegExp(r'[\x00-\x1F<>:"|?*]'), '_').trim();
  if (name.isEmpty) name = 'attachment-${attachment.guid}';
  if (!name.contains('.')) {
    final ext = _extensionFor(attachment);
    if (ext != null) name = '$name$ext';
  }
  return name;
}

String? _extensionFor(AttachmentModel attachment) {
  final mime = attachment.mimeType ?? attachment.originalMimeType ?? '';
  if (attachment.isVoiceMessage) return '.caf';
  if (mime == 'image/jpeg') return '.jpg';
  if (mime == 'image/png') return '.png';
  if (mime == 'image/gif') return '.gif';
  if (mime == 'image/heic' || mime == 'image/heif') return '.heic';
  if (mime == 'image/tiff') return '.tiff';
  if (mime == 'video/quicktime') return '.mov';
  if (mime == 'video/mp4') return '.mp4';
  if (mime == 'audio/x-m4a' || mime == 'audio/mp4') return '.m4a';
  if (mime == 'audio/x-caf') return '.caf';
  if (mime == 'application/pdf') return '.pdf';
  return null;
}

class _LinkAttachment extends StatelessWidget {
  final AttachmentModel attachment;
  const _LinkAttachment({required this.attachment});

  @override
  Widget build(BuildContext context) {
    return UrlPreviewCard(url: attachment.displayName, compact: true);
  }
}

/// C37: an iMessage shared-location attachment. Apple stores it as a small
/// vlocation text payload carrying an Apple Maps URL; we fetch it, extract the
/// URL, and offer "Open in Maps". A clean card — never a raw/broken file card.
class _LocationAttachment extends StatefulWidget {
  final ApiClient api;
  final AttachmentModel attachment;
  const _LocationAttachment({required this.api, required this.attachment});

  @override
  State<_LocationAttachment> createState() => _LocationAttachmentState();
}

class _LocationAttachmentState extends State<_LocationAttachment> {
  late final Future<Uri?> _future = _loadMapUrl();

  Future<Uri?> _loadMapUrl() async {
    try {
      final bytes = await MediaCache.instance.attachmentFull(
        widget.api,
        widget.attachment.guid,
      );
      final text = utf8.decode(bytes, allowMalformed: true);
      // The vlocation body contains an Apple Maps URL (and/or a geo: URI).
      final match = RegExp(
        r'(?:https?:\/\/[^\s<>"]*maps[^\s<>"]+|geo:[-0-9.,?&=]+)',
        caseSensitive: false,
      ).firstMatch(text);
      if (match != null) {
        return Uri.tryParse(match.group(0)!.replaceAll(r'\', ''));
      }
    } catch (_) {
      // Fall through to a no-link card.
    }
    return null;
  }

  Future<void> _open(Uri url) async {
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      /* best-effort */
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<Uri?>(
      future: _future,
      builder: (context, snap) {
        final url = snap.data;
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: url == null ? null : () => _open(url),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.location_on, color: scheme.primary),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          MicaLocalizations.of(context).t('chat.location'),
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                        Text(
                          url == null
                              ? MicaLocalizations.of(context).t('chat.location')
                              : MicaLocalizations.of(
                                  context,
                                ).t('chat.openInMaps'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (url != null)
                    Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// C24: a video attachment preview — same inline thumbnail treatment as images,
/// with a play affordance over the server-provided Quick Look preview. The video
/// player is still only created on demand in the full-screen viewer.
class _VideoAttachment extends StatefulWidget {
  final ApiClient api;
  final AttachmentModel attachment;
  final void Function(Offset)? onLongPress;
  const _VideoAttachment({
    required this.api,
    required this.attachment,
    this.onLongPress,
  });

  @override
  State<_VideoAttachment> createState() => _VideoAttachmentState();
}

class _VideoAttachmentState extends State<_VideoAttachment> {
  Uint8List? _bytes;
  Future<Uint8List>? _future;

  @override
  void initState() {
    super.initState();
    final cacheKey = _videoPreviewCacheKey(widget.attachment);
    final cached = MediaCache.instance.memoryHit(cacheKey);
    if (cached != null) {
      _bytes = cached;
    } else {
      _future = _loadBytes();
    }
  }

  Future<Uint8List> _loadBytes() => MediaCache.instance.load(
    _videoPreviewCacheKey(widget.attachment),
    () => widget.api.getAttachmentPreviewBytes(widget.attachment),
  );

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null && bytes.isNotEmpty) return _preview(context, bytes);
    final placeholderWidth = MediaQuery.sizeOf(context).width * 0.58;
    return _MediaSwap(
      child: FutureBuilder<Uint8List>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return _MediaLoadingPlaceholder(
              key: const ValueKey('loading'),
              width: placeholderWidth,
              height: 200,
              icon: Icons.videocam_outlined,
            );
          }
          final bytes = snap.data;
          if (snap.hasError || bytes == null || bytes.isEmpty) {
            return _VideoFallbackCard(
            api: widget.api,
            attachment: widget.attachment,
              onLongPress: widget.onLongPress,
            );
          }
          return KeyedSubtree(
            key: const ValueKey('media'),
            child: _preview(context, bytes),
          );
        },
      ),
    );
  }

  Widget _preview(BuildContext context, Uint8List bytes) {
    final boxMaxWidth = MediaQuery.sizeOf(context).width * 0.82;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final decodeWidth = (boxMaxWidth * dpr).round().clamp(200, 900);
    return GestureDetector(
      onTap: () => FullscreenVideo.open(
        context,
        api: widget.api,
        attachment: widget.attachment,
      ),
      onLongPressStart: (d) => _tileLongPress(
        context,
        widget.onLongPress,
        d.globalPosition,
        api: widget.api,
        attachment: widget.attachment,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: 306,
          maxWidth: MediaQuery.sizeOf(context).width * 0.738,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                cacheWidth: decodeWidth,
                filterQuality: FilterQuality.low,
                errorBuilder: (_, _, _) => _VideoFallbackCard(
                  api: widget.api,
                  attachment: widget.attachment,
                  onLongPress: widget.onLongPress,
                ),
              ),
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.38),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 38,
                ),
              ),
              Positioned(
                left: 8,
                right: 8,
                bottom: 8,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.42),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Text(
                        widget.attachment.totalBytes > 0
                            ? _formatSize(widget.attachment.totalBytes)
                            : 'Video',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _videoPreviewCacheKey(AttachmentModel attachment) =>
    'video:${attachment.previewUrl ?? attachment.guid}';

class _VideoFallbackCard extends StatelessWidget {
  final ApiClient api;
  final AttachmentModel attachment;
  final void Function(Offset)? onLongPress;
  const _VideoFallbackCard({
    required this.api,
    required this.attachment,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () =>
          FullscreenVideo.open(context, api: api, attachment: attachment),
      onLongPressStart: (d) => _tileLongPress(
        context,
        onLongPress,
        d.globalPosition,
        api: api,
        attachment: attachment,
      ),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.play_circle_fill, color: scheme.primary, size: 30),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    attachment.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    attachment.totalBytes > 0
                        ? 'Video · ${_formatSize(attachment.totalBytes)}'
                        : 'Video · tap to play',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// C69: skeleton shown while media bytes load (memory miss → disk/network).
/// Shaped like a media bubble so the loaded image fades in *in place* inside
/// the same bubble instead of popping the layout open from nothing.
class _MediaLoadingPlaceholder extends StatefulWidget {
  final double width;
  final double height;
  final double radius;
  final IconData icon;
  const _MediaLoadingPlaceholder({
    super.key,
    required this.width,
    required this.height,
    this.radius = 12,
    this.icon = Icons.image_outlined,
  });

  @override
  State<_MediaLoadingPlaceholder> createState() =>
      _MediaLoadingPlaceholderState();
}

class _MediaLoadingPlaceholderState extends State<_MediaLoadingPlaceholder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: FadeTransition(
          opacity: Tween<double>(begin: 0.45, end: 0.85).animate(
            CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
          ),
          child: ColoredBox(
            color: scheme.surfaceContainerHighest,
            child: Center(
              child: Icon(
                widget.icon,
                size: 30,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// C69: one-bubble placeholder → media transition — fades the new content in
/// and eases the size change instead of a hard layout jump.
class _MediaSwap extends StatelessWidget {
  final Widget child;
  const _MediaSwap({required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.center,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        child: child,
      ),
    );
  }
}

/// C32: renders an iMessage sticker. Stickers are images (PNG/HEIC/GIF), so we
/// try to load + show the bitmap with sticker styling (transparent, no card,
/// tap to fade like BlueBubbles, long-press to enlarge). If the bytes can't be
/// fetched or decoded — common for third-party sticker packs in formats the
/// server can't preview — we show a clean "Sticker" chip instead of a broken
/// file card.
class _StickerAttachment extends StatefulWidget {
  final ApiClient api;
  final AttachmentModel attachment;
  final void Function(Offset)? onLongPress;
  const _StickerAttachment({
    required this.api,
    required this.attachment,
    this.onLongPress,
  });

  @override
  State<_StickerAttachment> createState() => _StickerAttachmentState();
}

class _StickerAttachmentState extends State<_StickerAttachment> {
  // Use already-cached bytes synchronously so scrolling back doesn't flash a
  // spinner before the sticker reappears (C51).
  Uint8List? _bytes;
  Future<Uint8List>? _future;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    final cacheKey = widget.attachment.previewUrl ?? widget.attachment.guid;
    final cached = MediaCache.instance.memoryHit(cacheKey);
    if (cached != null) {
      _bytes = cached;
    } else {
      _future = _load();
    }
  }

  Future<Uint8List> _load() =>
      MediaCache.instance.attachmentPreview(widget.api, widget.attachment);

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null) {
      return bytes.isEmpty ? const _StickerPlaceholder() : _sticker(bytes);
    }
    return _MediaSwap(
      child: FutureBuilder<Uint8List>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const _MediaLoadingPlaceholder(
              key: ValueKey('loading'),
              width: 120,
              height: 120,
              radius: 14,
              icon: Icons.auto_awesome_outlined,
            );
          }
          if (snap.hasError || snap.data == null || snap.data!.isEmpty) {
            return const _StickerPlaceholder();
          }
          return KeyedSubtree(
            key: const ValueKey('media'),
            child: _sticker(snap.data!),
          );
        },
      ),
    );
  }

  Widget _sticker(Uint8List bytes) {
    return GestureDetector(
      onTap: () => setState(() => _visible = !_visible),
      onLongPressStart: (d) => _tileLongPress(
        context,
        widget.onLongPress,
        d.globalPosition,
        api: widget.api,
        attachment: widget.attachment,
      ),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: _visible ? 1 : 0.25,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 144, maxWidth: 144),
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            cacheWidth: 288,
            filterQuality: FilterQuality.none,
            errorBuilder: (_, _, _) => const _StickerPlaceholder(),
          ),
        ),
      ),
    );
  }
}

/// Clean fallback for an un-renderable sticker — a small labelled chip, never a
/// broken/empty file card.
class _StickerPlaceholder extends StatelessWidget {
  const _StickerPlaceholder();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.auto_awesome_outlined,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            MicaLocalizations.of(context).t('chat.sticker'),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

class _PreviewUnavailableAttachment extends StatelessWidget {
  final ApiClient api;
  final AttachmentModel attachment;
  final void Function(Offset)? onLongPress;
  const _PreviewUnavailableAttachment({
    required this.api,
    required this.attachment,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onLongPressStart: (d) => _tileLongPress(
        context,
        onLongPress,
        d.globalPosition,
        api: api,
        attachment: attachment,
      ),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.image_not_supported_outlined,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('TIFF image'),
                  Text(
                    'Preview not available yet',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (attachment.displayName != 'Attachment')
                    Text(
                      attachment.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (attachment.totalBytes > 0)
                    Text(
                      _formatSize(attachment.totalBytes),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImageAttachment extends StatefulWidget {
  final ApiClient api;
  final AttachmentModel attachment;
  final List<AttachmentModel> siblings;
  final int index;
  final void Function(Offset)? onLongPress;
  const _ImageAttachment({
    required this.api,
    required this.attachment,
    required this.siblings,
    required this.index,
    this.onLongPress,
  });

  @override
  State<_ImageAttachment> createState() => _ImageAttachmentState();
}

class _ImageAttachmentState extends State<_ImageAttachment> {
  // Already-cached bytes are used synchronously so scrolling an image back into
  // view renders it immediately instead of flashing a spinner frame (C51).
  Uint8List? _bytes;
  Future<Uint8List>? _future;

  @override
  void initState() {
    super.initState();
    final cacheKey = widget.attachment.previewUrl ?? widget.attachment.guid;
    final cached = MediaCache.instance.memoryHit(cacheKey);
    if (cached != null) {
      _bytes = cached;
    } else {
      _future = _loadBytes();
    }
  }

  Future<Uint8List> _loadBytes() =>
      MediaCache.instance.attachmentPreview(widget.api, widget.attachment);

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null) return _image(context, bytes);
    final placeholderWidth = MediaQuery.sizeOf(context).width * 0.58;
    return _MediaSwap(
      child: FutureBuilder<Uint8List>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return _MediaLoadingPlaceholder(
              key: const ValueKey('loading'),
              width: placeholderWidth,
              height: 200,
            );
          }
          if (snap.hasError || snap.data == null) {
            return KeyedSubtree(
              key: const ValueKey('error'),
              child: _FileAttachment(
                api: widget.api,
                attachment: widget.attachment,
              ),
            );
          }
          return KeyedSubtree(
            key: const ValueKey('media'),
            child: _image(context, snap.data!),
          );
        },
      ),
    );
  }

  Widget _image(BuildContext context, Uint8List bytes) {
    // Decode at the size actually shown (display width × pixel ratio), capped at
    // the previous fixed 900px so it only ever decodes *smaller* — less decode
    // work and less memory per image when scrolling (C51).
    final isSticker = widget.attachment.isSticker;
    final boxMaxWidth = isSticker
        ? 180.0
        : MediaQuery.sizeOf(context).width * 0.738;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final decodeWidth = (boxMaxWidth * dpr).round().clamp(200, 900);
    return GestureDetector(
      onTap: () => MediaGalleryViewer.open(
        context,
        api: widget.api,
        images: widget.siblings,
        initialIndex: widget.index,
      ),
      onLongPressStart: (d) => _tileLongPress(
        context,
        widget.onLongPress,
        d.globalPosition,
        api: widget.api,
        attachment: widget.attachment,
      ),
      // Bounded inline thumbnail: cap height and downscale the decode
      // (cacheWidth) so a large photo never decodes at full resolution in
      // the scrolling list. Full-size loading happens in the media viewer.
      child: ConstrainedBox(
        constraints: isSticker
            ? const BoxConstraints(maxHeight: 180, maxWidth: 180)
            : BoxConstraints(
                maxHeight: 306,
                maxWidth: MediaQuery.sizeOf(context).width * 0.738,
              ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(isSticker ? 4 : 12),
          child: Image.memory(
            bytes,
            fit: isSticker ? BoxFit.contain : BoxFit.cover,
            gaplessPlayback: true,
            cacheWidth: decodeWidth,
            filterQuality: FilterQuality.low,
            errorBuilder: (_, _, _) =>
                _FileAttachment(api: widget.api, attachment: widget.attachment),
          ),
        ),
      ),
    );
  }
}

class _AudioAttachment extends StatefulWidget {
  final ApiClient api;
  final AttachmentModel attachment;
  final void Function(Offset)? onLongPress;
  const _AudioAttachment({
    required this.api,
    required this.attachment,
    this.onLongPress,
  });

  @override
  State<_AudioAttachment> createState() => _AudioAttachmentState();
}

class _AudioAttachmentState extends State<_AudioAttachment> {
  final AudioPlayer _player = AudioPlayer();
  bool _loaded = false;
  bool _failed = false;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    try {
      if (!_loaded) {
        await _player.setUrl(
          widget.api.attachmentPlayableUrl(widget.attachment.guid),
          headers: widget.api.mediaAuthHeaders, // token in header, not URL
        );
        _loaded = true;
      }
      if (_player.playing) {
        await _player.pause();
      } else {
        // Restart if finished.
        if (_player.processingState == ProcessingState.completed) {
          await _player.seek(Duration.zero);
        }
        await _player.play();
      }
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = Color.alphaBlend(
      scheme.primary.withValues(alpha: 0.18),
      scheme.surface,
    );
    final fg = scheme.onSurface;
    return GestureDetector(
      onLongPressStart: (d) => _tileLongPress(
        context,
        widget.onLongPress,
        d.globalPosition,
        api: widget.api,
        attachment: widget.attachment,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: 260,
          maxWidth: _audioCardMaxWidth(context),
          minHeight: 64,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: StreamBuilder<PlayerState>(
              stream: _player.playerStateStream,
              builder: (context, stateSnap) {
                final playing = stateSnap.data?.playing ?? false;
                return StreamBuilder<Duration?>(
                  stream: _player.durationStream,
                  builder: (context, durationSnap) {
                    final duration = durationSnap.data ?? _player.duration;
                    return StreamBuilder<Duration>(
                      stream: _player.positionStream,
                      builder: (context, positionSnap) {
                        final position = positionSnap.data ?? _player.position;
                        final progress =
                            duration == null || duration.inMilliseconds <= 0
                            ? 0.0
                            : (position.inMilliseconds /
                                      duration.inMilliseconds)
                                  .clamp(0.0, 1.0)
                                  .toDouble();
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Material(
                              color: scheme.surface.withValues(alpha: 0.80),
                              shape: const CircleBorder(),
                              child: IconButton(
                                tooltip: _failed
                                    ? 'Audio unavailable'
                                    : playing
                                    ? 'Pause'
                                    : 'Play',
                                onPressed: _failed ? null : _toggle,
                                color: scheme.primary,
                                icon: Icon(
                                  _failed
                                      ? Icons.error_outline
                                      : playing
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _AudioWaveform(
                                progress: progress,
                                color: fg,
                                activeColor: scheme.primary,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              _failed
                                  ? '--:--'
                                  : _formatDuration(duration ?? position),
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  double _audioCardMaxWidth(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= 840) return 420;
    final maxWidth = width * 0.76;
    return maxWidth < 260 ? 260 : maxWidth;
  }

  String _formatDuration(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _AudioWaveform extends StatelessWidget {
  final double progress;
  final Color color;
  final Color activeColor;

  const _AudioWaveform({
    required this.progress,
    required this.color,
    required this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _AudioWaveformPainter(
        progress: progress,
        color: color,
        activeColor: activeColor,
      ),
      child: const SizedBox(height: 30),
    );
  }
}

class _AudioWaveformPainter extends CustomPainter {
  final double progress;
  final Color color;
  final Color activeColor;

  const _AudioWaveformPainter({
    required this.progress,
    required this.color,
    required this.activeColor,
  });

  static const List<double> _levels = [
    0.16,
    0.20,
    0.18,
    0.24,
    0.22,
    0.28,
    0.26,
    0.34,
    0.48,
    0.62,
    0.74,
    0.68,
    0.56,
    0.50,
    0.44,
    0.58,
    0.66,
    0.52,
    0.48,
    0.72,
    0.80,
    0.74,
    0.78,
    0.76,
    0.70,
    0.60,
    0.52,
    0.48,
    0.42,
    0.36,
    0.30,
    0.26,
    0.22,
    0.18,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final inactive = Paint()
      ..color = color.withValues(alpha: 0.46)
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3;
    final active = Paint()
      ..color = activeColor.withValues(alpha: 0.88)
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3;
    final gap = size.width / _levels.length;
    final center = size.height / 2;
    final activeCutoff = progress.clamp(0.0, 1.0) * size.width;
    for (var i = 0; i < _levels.length; i++) {
      final height = 5 + _levels[i] * (size.height - 8);
      final x = gap * i + gap / 2;
      canvas.drawLine(
        Offset(x, center - height / 2),
        Offset(x, center + height / 2),
        x <= activeCutoff ? active : inactive,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _AudioWaveformPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.color != color ||
        oldDelegate.activeColor != activeColor;
  }
}

class _FileAttachment extends StatelessWidget {
  final ApiClient api;
  final AttachmentModel attachment;
  final void Function(Offset)? onLongPress;
  const _FileAttachment({
    required this.api,
    required this.attachment,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = Color.alphaBlend(
      scheme.primary.withValues(alpha: 0.18),
      scheme.surface,
    );
    final fg = scheme.onSurface;
    final meta = [
      _extensionLabel(attachment),
      if (attachment.totalBytes > 0) _humanSize(attachment.totalBytes),
    ].where((s) => s.isNotEmpty).join('  ');
    return GestureDetector(
      onLongPressStart: (d) => _tileLongPress(
        context,
        onLongPress,
        d.globalPosition,
        api: api,
        attachment: attachment,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: 260,
          maxWidth: _fileCardMaxWidth(context),
          minHeight: 84,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: scheme.surface.withValues(alpha: 0.70),
                  child: Icon(_iconFor(attachment), color: fg, size: 28),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        attachment.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(color: fg, fontWeight: FontWeight.w700),
                      ),
                      if (meta.isNotEmpty)
                        Text(
                          meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: scheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Attachment actions',
                  color: scheme.onSurfaceVariant,
                  onPressed: () => showAttachmentActions(
                    context,
                    api: api,
                    attachment: attachment,
                  ),
                  icon: const Icon(Icons.more_vert),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _iconFor(AttachmentModel a) {
    if (a.isVideo) return Icons.movie_outlined;
    if (a.isSticker) return Icons.emoji_emotions_outlined;
    final mime = a.mimeType ?? '';
    if (mime == 'application/pdf') return Icons.picture_as_pdf_outlined;
    if (mime.startsWith('text/')) return Icons.description_outlined;
    return Icons.insert_drive_file_outlined;
  }

  double _fileCardMaxWidth(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final proportionalWidth = width * 0.78;
    final maxWidth = width >= 840 ? 560.0 : proportionalWidth;
    return maxWidth < 260 ? 260 : maxWidth;
  }

  String _humanSize(int bytes) => _formatSize(bytes);

  String _extensionLabel(AttachmentModel a) {
    final name = a.displayName;
    final idx = name.lastIndexOf('.');
    if (idx >= 0 && idx < name.length - 1) {
      return name.substring(idx + 1).toUpperCase();
    }
    final mime = a.mimeType ?? a.originalMimeType ?? '';
    final slash = mime.indexOf('/');
    if (slash >= 0 && slash < mime.length - 1) {
      return mime.substring(slash + 1).toUpperCase();
    }
    return a.displayKind == 'unknown' ? 'FILE' : a.displayKind.toUpperCase();
  }
}

String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
