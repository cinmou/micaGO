import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/theme_controller.dart';
import '../../core/ui/glass_theme_widgets.dart';
import 'chat_list_screen.dart';
import 'message_thread_screen.dart';
import 'models/merged_chat.dart';

/// Responsive Chats surface:
/// - **compact** (phone): single pane — tapping a chat pushes the thread.
/// - **wide** (tablet / desktop): two-pane — chat list on the left, the selected
///   thread on the right, with a clean empty state when nothing is selected.
///
/// The selected chat is held in state, so it survives rotation / window resize.
class ChatsPane extends StatefulWidget {
  final ValueListenable<int>? searchRequests;
  final VoidCallback? onSearchRequested;
  final VoidCallback? onOpenSettings;

  const ChatsPane({
    super.key,
    this.searchRequests,
    this.onSearchRequested,
    this.onOpenSettings,
  });

  @override
  State<ChatsPane> createState() => _ChatsPaneState();
}

class _ChatsPaneState extends State<ChatsPane> {
  MergedChat? _selected;
  double _sidebarWidth = _defaultSidebarWidth;
  bool _loadedSidebarWidth = false;
  bool _draggingSplitter = false;

  static const double _tabletBreakpoint = 840;
  static const double _collapsedSidebarWidth = 80;
  static const double _compactThreshold = 160;
  static const double _minExpandedSidebarWidth = 280;
  static const double _defaultSidebarWidth = 360;
  static const double _maxSidebarWidth = 480;
  static const double _tabletHeaderHeight = 72;
  static const String _sidebarWidthKey = 'tablet_sidebar_width';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loadedSidebarWidth) return;
    _loadedSidebarWidth = true;
    final cache = context.read<AppController>().cache;
    cache.readMetadata(_sidebarWidthKey).then((value) {
      if (!mounted || value == null) return;
      final parsed = double.tryParse(value);
      if (parsed == null) return;
      setState(() {
        _sidebarWidth = parsed.clamp(_collapsedSidebarWidth, _maxSidebarWidth);
      });
    });
  }

  bool get _compactSidebar => _sidebarWidth < _compactThreshold;

  void _updateSidebarWidth(double delta) {
    setState(() {
      _sidebarWidth = (_sidebarWidth + delta).clamp(
        _collapsedSidebarWidth,
        _maxSidebarWidth,
      );
    });
  }

  void _settleSidebarWidth() {
    final next = _sidebarWidth < _compactThreshold
        ? _collapsedSidebarWidth
        : _sidebarWidth.clamp(_minExpandedSidebarWidth, _maxSidebarWidth);
    setState(() {
      _draggingSplitter = false;
      _sidebarWidth = next;
    });
    context.read<AppController>().cache.writeMetadata(
      _sidebarWidthKey,
      next.toStringAsFixed(1),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tablet = constraints.maxWidth >= _tabletBreakpoint;

        if (!tablet) {
          return ChatListScreen(
            searchRequests: widget.searchRequests,
            onOpen: (merged) => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => MessageThreadScreen(merged: merged),
              ),
            ),
          );
        }

        final scheme = Theme.of(context).colorScheme;
        final theme = context.watch<ThemeController>();
        final glass = theme.useLiquidGlass;
        final inkWash = theme.useBlackWhite;
        final glassBg = liquidGlassPageColor(context);
        final headerBg = glass
            ? glassBg
            : inkWash
            ? scheme.surface
            : _chatsAccent1_100(scheme);
        final pageBg = glass
            ? glassBg
            : inkWash
            ? scheme.surface
            : _chatsAccent1_50(scheme);
        final compact = _compactSidebar;
        return Row(
          children: [
            AnimatedContainer(
              duration: _draggingSplitter
                  ? Duration.zero
                  : const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              width: _sidebarWidth,
              color: headerBg,
              child: Column(
                children: [
                  _TabletSidebarHeader(
                    compact: compact,
                    height: _tabletHeaderHeight,
                    onSearch: widget.onSearchRequested,
                    onSettings: widget.onOpenSettings,
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(24),
                      ),
                      child: ColoredBox(
                        color: pageBg,
                        child: ChatListScreen(
                          searchRequests: compact
                              ? null
                              : widget.searchRequests,
                          compact: compact,
                          sidebar: true,
                          selectedGuid: _selected?.primary.guid,
                          onOpen: (merged) =>
                              setState(() => _selected = merged),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _SplitHandle(
              dragging: _draggingSplitter,
              onDragStart: () => setState(() => _draggingSplitter = true),
              onDragUpdate: _updateSidebarWidth,
              onDragEnd: _settleSidebarWidth,
            ),
            Expanded(
              child: _selected == null
                  ? const _NoSelection()
                  : MessageThreadScreen(
                      key: ValueKey(_selected!.key),
                      merged: _selected!,
                      embedded: true,
                      flatSplitView: true,
                      embeddedHeaderHeight: _tabletHeaderHeight,
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _TabletSidebarHeader extends StatelessWidget {
  final bool compact;
  final double height;
  final VoidCallback? onSearch;
  final VoidCallback? onSettings;

  const _TabletSidebarHeader({
    required this.compact,
    required this.height,
    required this.onSearch,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (compact) {
      return DecoratedBox(
        decoration: BoxDecoration(color: _chatsAccent1_100(scheme)),
        child: SizedBox(
          height: height,
          child: Center(
            child: IconButton(
              tooltip: strings.t('nav.settings'),
              icon: const Icon(Icons.settings_outlined),
              onPressed: onSettings,
            ),
          ),
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(color: _chatsAccent1_100(scheme)),
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            const SizedBox(width: 12),
            IconButton(
              tooltip: 'Search',
              icon: const Icon(Icons.search),
              onPressed: onSearch,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                'micaGO',
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: strings.t('nav.settings'),
              icon: const Icon(Icons.settings_outlined),
              onPressed: onSettings,
            ),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}

class _SplitHandle extends StatefulWidget {
  final bool dragging;
  final VoidCallback onDragStart;
  final ValueChanged<double> onDragUpdate;
  final VoidCallback onDragEnd;

  const _SplitHandle({
    required this.dragging,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  @override
  State<_SplitHandle> createState() => _SplitHandleState();
}

class _SplitHandleState extends State<_SplitHandle> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = _hovering || widget.dragging;
    final idleColor = _chatsAccent1_100(scheme);
    final activeColor = Color.alphaBlend(
      scheme.primary.withValues(alpha: 0.18),
      idleColor,
    );
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => widget.onDragStart(),
        onHorizontalDragUpdate: (details) =>
            widget.onDragUpdate(details.delta.dx),
        onHorizontalDragEnd: (_) => widget.onDragEnd(),
        onHorizontalDragCancel: widget.onDragEnd,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: active ? 8 : 6,
          alignment: Alignment.center,
          color: active ? activeColor : idleColor,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: active ? 4 : 2,
            height: double.infinity,
            color: active
                ? scheme.primary.withValues(alpha: 0.20)
                : Colors.transparent,
          ),
        ),
      ),
    );
  }
}

Color _chatsAccent1_50(ColorScheme scheme) =>
    Color.alphaBlend(scheme.primary.withValues(alpha: 0.10), scheme.surface);

Color _chatsAccent1_100(ColorScheme scheme) => Color.alphaBlend(
  scheme.primary.withValues(alpha: 0.18),
  scheme.surfaceContainerLowest,
);

class _NoSelection extends StatelessWidget {
  const _NoSelection();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forum_outlined, size: 56, color: scheme.outline),
          const SizedBox(height: 12),
          Text(
            'Select a chat',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
