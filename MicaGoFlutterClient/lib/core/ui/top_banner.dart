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

  static OverlayEntry? _entry;
  static String? _lastMessage;
  static DateTime? _lastShownAt;

  /// Shows [message] as a top banner over the root overlay. Repeated identical
  /// messages within 3s are suppressed to avoid noisy repeats.
  static void show(
    BuildContext context,
    String message, {
    TopBannerKind kind = TopBannerKind.info,
    Duration duration = const Duration(seconds: 3),
  }) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) return;
    final now = DateTime.now();
    if (_lastMessage == trimmed &&
        _lastShownAt != null &&
        now.difference(_lastShownAt!) < const Duration(seconds: 3)) {
      return;
    }
    _lastMessage = trimmed;
    _lastShownAt = now;

    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    _entry?.remove();
    _entry = null;

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _TopBannerView(
        message: trimmed,
        kind: kind,
        duration: duration,
        onDismissed: () {
          if (identical(_entry, entry)) _entry = null;
          entry.remove();
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }
}

class _TopBannerView extends StatefulWidget {
  final String message;
  final TopBannerKind kind;
  final Duration duration;
  final VoidCallback onDismissed;

  const _TopBannerView({
    required this.message,
    required this.kind,
    required this.duration,
    required this.onDismissed,
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isError = widget.kind == TopBannerKind.error;
    final bg = isError ? scheme.errorContainer : scheme.inverseSurface;
    final fg = isError ? scheme.onErrorContainer : scheme.onInverseSurface;
    final topInset = MediaQuery.of(context).padding.top;

    final curved = CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic);
    return Positioned(
      top: topInset,
      left: 12,
      right: 12,
      child: IgnorePointer(
        ignoring: false,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, -1.2),
            end: Offset.zero,
          ).animate(curved),
          child: FadeTransition(
            opacity: curved,
            child: Material(
              color: Colors.transparent,
              child: GestureDetector(
                onTap: _dismiss,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isError ? Icons.error_outline : Icons.info_outline,
                        size: 18,
                        color: fg,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          widget.message,
                          style: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.copyWith(color: fg),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
