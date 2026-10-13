import 'dart:typed_data';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../core/l10n/app_localizations.dart';

/// One attachment staged for sending (selected but not yet sent). [sourceId] is
/// the gallery asset id when picked from the media grid, so the grid can show a
/// selected check and toggle it off; null for camera/file picks.
class StagedAttachment {
  final Uint8List? bytes;
  final String? path;
  final int size;
  final Uint8List? thumbnail;
  final double? previewAspectRatio;
  final String filename;
  final String? sourceId;
  final bool isAudioMessage;
  StagedAttachment({
    required Uint8List bytes,
    required this.filename,
    this.sourceId,
    this.isAudioMessage = false,
  }) : bytes = bytes,
       path = null,
       size = bytes.length,
       previewAspectRatio = null,
       thumbnail = null;

  const StagedAttachment.file({
    required this.path,
    required this.size,
    required this.filename,
    this.thumbnail,
    this.previewAspectRatio,
    this.sourceId,
    this.isAudioMessage = false,
  }) : bytes = null;

  Future<Uint8List> readBytes() =>
      path == null ? Future.value(bytes!) : File(path!).readAsBytes();

  Future<Uint8List> previewBytes() async {
    if (thumbnail != null) return thumbnail!;
    if (!isImage) return Uint8List(0);
    final buffer = path != null
        ? await ui.ImmutableBuffer.fromFilePath(path!)
        : await ui.ImmutableBuffer.fromUint8List(bytes!);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        final width = descriptor.width.clamp(1, 720);
        final codec = await descriptor.instantiateCodec(targetWidth: width);
        try {
          final frame = await codec.getNextFrame();
          try {
            final data = await frame.image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            if (data == null) {
              throw StateError('Could not encode attachment preview');
            }
            return data.buffer.asUint8List();
          } finally {
            frame.image.dispose();
          }
        } finally {
          codec.dispose();
        }
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }

  bool get isImage {
    final n = filename.toLowerCase();
    return n.endsWith('.jpg') ||
        n.endsWith('.jpeg') ||
        n.endsWith('.png') ||
        n.endsWith('.gif') ||
        n.endsWith('.heic') ||
        n.endsWith('.webp');
  }
}

/// BlueBubbles-style attachment panel (adapted from
/// `text_field_attachment_picker.dart`): the **+** opens this in-composer panel
/// showing a horizontal grid of **recent gallery media** (via photo_manager)
/// preceded by Camera / Files action tiles. Tapping a thumbnail toggles
/// it into the staged selection (check overlay), matching BB's multi-select.
/// Permission states (granted / limited / denied / permanently denied) are
/// handled; the generic file picker is always available as a fallback.
class AttachmentPanel extends StatefulWidget {
  /// Currently-staged asset ids (to render check overlays).
  final Set<String> selectedAssetIds;

  /// Toggle a gallery asset in/out of the staged selection.
  final Future<void> Function(AssetEntity asset) onToggleAsset;

  /// Files / camera picks (already-loaded bytes).
  final void Function(List<StagedAttachment>) onPicked;

  /// Surface a permission/error message to the user.
  final void Function(String message) onError;

  const AttachmentPanel({
    super.key,
    required this.selectedAssetIds,
    required this.onToggleAsset,
    required this.onPicked,
    required this.onError,
  });

  /// The panel's on-screen height, so the thread can reserve matching bottom
  /// space in the message list (C50). Kept in sync with [build].
  static double panelHeightFor(BuildContext context) =>
      (MediaQuery.sizeOf(context).height * 0.50).clamp(300.0, 460.0);

  @override
  State<AttachmentPanel> createState() => _AttachmentPanelState();
}

class _AttachmentPanelState extends State<AttachmentPanel> {
  List<AssetEntity> _recent = const [];
  PermissionState? _permission;
  bool _loading = true;
  bool _pickingCamera = false;

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  bool get _hasNativeGallery => Platform.isAndroid || Platform.isIOS;

  Future<void> _loadRecent() async {
    if (!_hasNativeGallery) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    // Like BB: request extended permission (covers iOS limited library) and
    // load the most recent gallery items for the grid.
    try {
      final ps = await PhotoManager.requestPermissionExtend();
      if (!mounted) return;
      _permission = ps;
      if (!ps.hasAccess) {
        setState(() => _loading = false);
        return;
      }
      final albums = await PhotoManager.getAssetPathList(
        onlyAll: true,
        type: RequestType.common, // images + videos
        filterOption: FilterOptionGroup(
          orders: const [
            OrderOption(type: OrderOptionType.createDate, asc: false),
          ],
        ),
      );
      if (albums.isNotEmpty) {
        _recent = await albums.first.getAssetListRange(start: 0, end: 31);
      }
    } catch (e) {
      if (!mounted) return;
      widget.onError(
        MicaLocalizations.current
            .t('chat.recentMediaFailed')
            .replaceAll('{error}', '$e'),
      );
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _pickCamera() async {
    if (_pickingCamera) return;
    _pickingCamera = true;
    try {
      final picker = ImagePicker();
      final file = await picker.pickImage(source: ImageSource.camera);
      if (file == null || !mounted) return;
      final size = await file.length();
      if (!mounted) return;
      widget.onPicked([
        StagedAttachment.file(path: file.path, size: size, filename: file.name),
      ]);
    } catch (e) {
      if (!mounted) return;
      widget.onError(
        MicaLocalizations.current
            .t('chat.cameraFailed')
            .replaceAll('{error}', '$e'),
      );
    } finally {
      _pickingCamera = false;
    }
  }

  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        withData: false,
        allowMultiple: true,
      );
      final picked = <StagedAttachment>[];
      for (final f in result?.files ?? const <PlatformFile>[]) {
        final path = f.path;
        if (path != null) {
          picked.add(
            StagedAttachment.file(path: path, size: f.size, filename: f.name),
          );
        }
      }
      if (mounted && picked.isNotEmpty) widget.onPicked(picked);
    } catch (e) {
      if (!mounted) return;
      widget.onError(
        MicaLocalizations.current
            .t('chat.filesFailed')
            .replaceAll('{error}', '$e'),
      );
    }
  }

  Future<void> _pickMoreImages() async {
    try {
      final files = await ImagePicker().pickMultiImage();
      final picked = <StagedAttachment>[];
      for (final file in files) {
        picked.add(
          StagedAttachment.file(
            path: file.path,
            size: await file.length(),
            filename: file.name,
          ),
        );
      }
      if (mounted && picked.isNotEmpty) widget.onPicked(picked);
    } catch (e) {
      if (!mounted) return;
      widget.onError(
        MicaLocalizations.current
            .t('chat.photoPickerFailed')
            .replaceAll('{error}', '$e'),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final height = AttachmentPanel.panelHeightFor(context);
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(18),
          topRight: Radius.circular(18),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            SizedBox(
              height: 20,
              child: Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : CustomScrollView(
                      scrollDirection: Axis.horizontal,
                      slivers: [
                        // Leading action tiles (always available).
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(8, 0, 0, 8),
                          sliver: SliverGrid(
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 2,
                                  mainAxisExtent: 118,
                                  mainAxisSpacing: 8,
                                  crossAxisSpacing: 8,
                                ),
                            delegate: SliverChildListDelegate([
                              // C21: Camera + Files only. The standalone "Video" tile was
                              // removed — recent videos are pickable straight from the
                              // grid below (they carry a play badge and send like any
                              // other attachment).
                              if (_hasNativeGallery)
                                _ActionTile(
                                  icon: Icons.photo_camera_outlined,
                                  label: MicaLocalizations.of(
                                    context,
                                  ).t('chat.camera'),
                                  onTap: _pickCamera,
                                ),
                              if (!_hasNativeGallery)
                                _ActionTile(
                                  icon: Icons.photo_library_outlined,
                                  label: MicaLocalizations.of(
                                    context,
                                  ).t('chat.photos'),
                                  onTap: _pickMoreImages,
                                ),
                              _ActionTile(
                                icon: Icons.folder_open_outlined,
                                label: MicaLocalizations.of(
                                  context,
                                ).t('chat.files'),
                                onTap: _pickFiles,
                              ),
                              if (_permission == PermissionState.limited)
                                _ActionTile(
                                  icon: Icons.add_photo_alternate_outlined,
                                  label: MicaLocalizations.of(
                                    context,
                                  ).t('chat.morePhotos'),
                                  onTap: () => PhotoManager.presentLimited(),
                                ),
                            ]),
                          ),
                        ),
                        const SliverPadding(padding: EdgeInsets.only(left: 8)),
                        // Recent gallery media grid (the BlueBubbles hallmark).
                        if (_permission?.hasAccess ?? false)
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(0, 0, 8, 8),
                            sliver: SliverGrid(
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 2,
                                    mainAxisSpacing: 8,
                                    crossAxisSpacing: 8,
                                  ),
                              delegate: SliverChildBuilderDelegate((
                                context,
                                i,
                              ) {
                                if (i == _recent.length) {
                                  return _MorePhotosTile(
                                    onTap: _pickMoreImages,
                                  );
                                }
                                return _MediaTile(
                                  asset: _recent[i],
                                  selected: widget.selectedAssetIds.contains(
                                    _recent[i].id,
                                  ),
                                  onTap: () => widget.onToggleAsset(_recent[i]),
                                );
                              }, childCount: _recent.length + 1),
                            ),
                          )
                        else if (_hasNativeGallery)
                          SliverToBoxAdapter(
                            child: _PermissionPrompt(state: _permission),
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

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 118,
      child: Material(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 28, color: scheme.onPrimary),
              const SizedBox(height: 6),
              Text(
                label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MediaTile extends StatefulWidget {
  final AssetEntity asset;
  final bool selected;
  final VoidCallback onTap;
  const _MediaTile({
    required this.asset,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_MediaTile> createState() => _MediaTileState();
}

class _MediaTileState extends State<_MediaTile> {
  Uint8List? _thumb;

  @override
  void initState() {
    super.initState();
    widget.asset.thumbnailDataWithSize(const ThumbnailSize.square(360)).then((
      data,
    ) {
      if (mounted) setState(() => _thumb = data);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 96,
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: _thumb != null
                  ? Image.memory(_thumb!, fit: BoxFit.cover)
                  : Container(color: scheme.surface),
            ),
            // Video badge.
            if (widget.asset.type == AssetType.video && !widget.selected)
              const Positioned(
                right: 4,
                bottom: 4,
                child: Icon(
                  Icons.play_circle_fill,
                  color: Colors.white,
                  size: 22,
                ),
              ),
            // Selected check overlay (BB-style).
            if (widget.selected)
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: scheme.primary.withValues(alpha: 0.35),
                ),
                alignment: Alignment.topRight,
                padding: const EdgeInsets.all(4),
                child: CircleAvatar(
                  radius: 11,
                  backgroundColor: scheme.primary,
                  child: Icon(Icons.check, size: 14, color: scheme.onPrimary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MorePhotosTile extends StatelessWidget {
  final VoidCallback onTap;
  const _MorePhotosTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 96,
      child: Material(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.photo_library_outlined, color: scheme.onPrimary),
              const SizedBox(height: 6),
              Text(
                MicaLocalizations.of(context).t('chat.more'),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PermissionPrompt extends StatelessWidget {
  final PermissionState? state;
  const _PermissionPrompt({required this.state});

  @override
  Widget build(BuildContext context) {
    final denied =
        state == PermissionState.denied || state == PermissionState.restricted;
    return SizedBox(
      width: 220,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.photo_library_outlined, size: 28),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                denied
                    ? MicaLocalizations.of(context).t('chat.photoAccessOff')
                    : MicaLocalizations.of(context).t('chat.photoAccessAsk'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: () => PhotoManager.openSetting(),
              child: Text(
                MicaLocalizations.of(context).t('common.openSettings'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Horizontal preview strip of staged attachments with per-item remove.
class StagedAttachmentStrip extends StatelessWidget {
  final List<StagedAttachment> items;
  final void Function(int index) onRemove;
  const StagedAttachmentStrip({
    super.key,
    required this.items,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final item = items[i];
          return Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child:
                    item.isImage &&
                        (item.thumbnail != null || item.bytes != null)
                    ? Image.memory(
                        item.thumbnail ?? item.bytes!,
                        width: 60,
                        height: 60,
                        cacheWidth:
                            (60 * MediaQuery.devicePixelRatioOf(context))
                                .ceil(),
                        errorBuilder: (_, _, _) => const SizedBox(
                          width: 60,
                          height: 60,
                          child: Icon(Icons.broken_image_outlined),
                        ),
                        fit: BoxFit.cover,
                      )
                    : item.isImage && item.path != null
                    ? Image.file(
                        File(item.path!),
                        width: 60,
                        height: 60,
                        cacheWidth:
                            (60 * MediaQuery.devicePixelRatioOf(context))
                                .ceil(),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const SizedBox(
                          width: 60,
                          height: 60,
                          child: Icon(Icons.broken_image_outlined),
                        ),
                      )
                    : Container(
                        width: 60,
                        height: 60,
                        color: scheme.surfaceContainerHighest,
                        alignment: Alignment.center,
                        child: const Icon(Icons.insert_drive_file_outlined),
                      ),
              ),
              Positioned(
                top: -6,
                right: -6,
                child: IconButton(
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.cancel),
                  color: scheme.onSurfaceVariant,
                  onPressed: () => onRemove(i),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
