import 'dart:async';

import 'package:flutter/material.dart';

/// Visual intent for a top banner.
enum TopBannerKind { info, error }

/// C21u: a single, top-anchored transient notice that slides in **under the
/// title bar / status bar** instead of using Material's bottom snackbars. All
/// in-app system messages (connection lost/recovered, fallback switch, send /
/// refresh failed, media-permission and attachment errors) route through here
/// so they appear in the top app area and never stack at the bottom.
///
/// It is intentionally minimal and de-duplicated: an identical message shown
/// again within a short window is ignored, and a new message replaces the one
/// currently on screen rather than piling up.
class TopBanner {
  TopBanner._();

  static bool blocked = false;
  static OverlayEntry? _entry;
  static Completer<void>? _closed;
  static String? _lastMessage;
  static DateTime? _lastShownAt;

  static void dismiss() {
    _entry?.remove();
    _entry = null;
    if (_closed?.isCompleted == false) _closed!.complete();
    _closed = null;
  }

  /// Shows [message] as a top banner over the root overlay. Repeated identical
  /// messages within 3s are suppressed to avoid noisy repeats.
  static Future<void> show(
    BuildContext context,
    String message, {
    TopBannerKind kind = TopBannerKind.info,
    Duration duration = const Duration(seconds: 3),
    String? actionLabel,
    FutureOr<void> Function()? onAction,
  }) {
    if (blocked) return Future.value();
    final trimmed = message.trim();
    if (trimmed.isEmpty) return Future.value();
    final now = DateTime.now();
    if (onAction == null &&
        _lastMessage == trimmed &&
        _lastShownAt != null &&
        now.difference(_lastShownAt!) < const Duration(seconds: 3)) {
      return _closed?.future ?? Future.value();
    }
    _lastMessage = trimmed;
    _lastShownAt = now;

    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return Future.value();

    dismiss();
    final closed = Completer<void>();
    _closed = closed;

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _TopBannerView(
        message: trimmed,
        kind: kind,
        duration: duration,
        actionLabel: actionLabel,
        onAction: onAction,
        onRemoved: () {
          if (identical(_entry, entry)) {
            _entry = null;
            _closed = null;
          }
          if (!closed.isCompleted) closed.complete();
        },
        onDismissed: () {
          if (identical(_entry, entry)) {
            dismiss();
          }
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
    return closed.future;
  }
}

class _TopBannerView extends StatefulWidget {
  final String message;
  final TopBannerKind kind;
  final Duration duration;
  final VoidCallback onDismissed;
  final VoidCallback onRemoved;
  final String? actionLabel;
  final FutureOr<void> Function()? onAction;

  const _TopBannerView({
    required this.message,
    required this.kind,
    required this.duration,
    required this.onDismissed,
    required this.onRemoved,
    this.actionLabel,
    this.onAction,
  });

  @override
  State<_TopBannerView> createState() => _TopBannerViewState();
}

class _TopBannerViewState extends State<_TopBannerView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Timer? _autoHide;
  bool _dismissing = false;
  bool _acting = false;

  @override
  void initState() {
    super.initState();
    _anim.forward();
    _autoHide = Timer(widget.duration, _dismiss);
  }

  Future<void> _dismiss() async {
    if (_dismissing) return;
    _dismissing = true;
    _autoHide?.cancel();
    if (mounted) await _anim.reverse();
    widget.onDismissed();
  }

  @override
  void dispose() {
    _autoHide?.cancel();
    _anim.dispose();
    widget.onRemoved();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic);
    return Positioned(
      top: MediaQuery.paddingOf(context).top + kToolbarHeight + 8,
      left: 12,
      right: 12,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -1.2),
              end: Offset.zero,
            ).animate(curved),
            child: FadeTransition(
              opacity: curved,
              child: GestureDetector(
                onTap: _dismiss,
                child: AppNoticeCard(
                  message: widget.message,
                  kind: TopBannerKind.info,
                  actionLabel: widget.actionLabel,
                  onAction: widget.onAction == null
                      ? null
                      : () async {
                          if (_acting || _dismissing) return;
                          _acting = true;
                          try {
                            await widget.onAction!();
                          } finally {
                            _acting = false;
                            await _dismiss();
                          }
                        },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared surface for transient notices and the connection retry notice.
class AppNoticeCard extends StatelessWidget {
  final String message;
  final TopBannerKind kind;
  final String? actionLabel;
  final VoidCallback? onAction;
  const AppNoticeCard({
    super.key,
    required this.message,
    this.kind = TopBannerKind.info,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final error = kind == TopBannerKind.error;
    final foreground = error
        ? scheme.onErrorContainer
        : scheme.onInverseSurface;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Material(
        color: error ? scheme.errorContainer : scheme.inverseSurface,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 12,
            vertical: onAction == null ? 8 : 4,
          ),
          child: Row(
            children: [
              Icon(
                error ? Icons.error_outline : Icons.info_outline,
                size: 16,
                color: foreground,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: foreground),
                ),
              ),
              if (onAction != null && actionLabel != null)
                TextButton(
                  onPressed: onAction,
                  style: TextButton.styleFrom(
                    foregroundColor: foreground,
                    minimumSize: const Size(48, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: Text(actionLabel!),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
