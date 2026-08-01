import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/network/push_service.dart';
import '../../core/platform/incoming_share_service.dart';
import '../../core/theme_controller.dart';
import '../../core/ui/top_banner.dart';
import '../../core/ui/glass_theme_widgets.dart';
import '../../core/ui/keyboard_insets.dart';
import '../chats/chats_pane.dart';
import '../chats/avatar.dart';
import '../settings/settings_screen.dart';
import 'connection_notice_host.dart';

/// The post-pairing app shell: chat-first, with Settings as a secondary page.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  PushService? _push;
  AppController? _app;
  StreamSubscription<ForegroundMessageAlert>? _foregroundAlertSub;
  OverlayEntry? _foregroundAlertEntry;
  Timer? _foregroundAlertTimer;
  Timer? _pushRetryTimer;
  final ValueNotifier<int> _searchRequests = ValueNotifier<int>(0);
  static const double _tabletBreakpoint = 840;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Open the realtime socket + load endpoints once the shell appears.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final app = context.read<AppController>();
      _app = app;
      unawaited(app.connectForeground(reason: 'startup'));
      app.refreshServerUrls().catchError((_) {});
      // C22: start the optional FCM wake path (no-op without Firebase config).
      _push = PushService(app);
      unawaited(_push!.start());
      _pushRetryTimer = Timer.periodic(const Duration(seconds: 20), (_) {
        final push = _push;
        if (push == null || push.available) {
          _pushRetryTimer?.cancel();
          _pushRetryTimer = null;
          return;
        }
        unawaited(push.start());
      });
      // A notification tap routes here: jump to the Chats tab so the chat opens.
      app.pendingOpenChat.addListener(_onOpenChatRequested);
      _foregroundAlertSub = app.foregroundMessageAlerts.listen(
        _onForegroundMessageAlert,
      );
      IncomingShareService.latest.addListener(_onIncomingShare);
      unawaited(IncomingShareService.start());
    });
  }

  void _onOpenChatRequested() {
    if (_app?.pendingOpenChat.value == null) return;
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _onIncomingShare() {
    final payload = IncomingShareService.latest.value;
    if (!mounted || payload == null) return;
    TopBanner.show(context, 'Shared to micaGO: ${payload.summary}');
    IncomingShareService.clear();
  }

  void _onForegroundMessageAlert(ForegroundMessageAlert alert) {
    if (!mounted) return;
    HapticFeedback.lightImpact();
    final app = _app ?? context.read<AppController>();
    if (!app.inAppNotificationsEnabled) return;
    _showForegroundAlert(alert);
  }

  void _showForegroundAlert(ForegroundMessageAlert alert) {
    _foregroundAlertTimer?.cancel();
    _foregroundAlertEntry?.remove();
    _foregroundAlertEntry = OverlayEntry(
      builder: (ctx) => _InAppMessageNotification(
        alert: alert,
        onTap: () {
          _dismissForegroundAlert();
          final app = _app ?? context.read<AppController>();
          app.requestOpenChat(alert.chatGuid);
          Navigator.of(context).popUntil((route) => route.isFirst);
        },
        onDismiss: _dismissForegroundAlert,
      ),
    );
    Overlay.of(context).insert(_foregroundAlertEntry!);
    _foregroundAlertTimer = Timer(
      const Duration(seconds: 4),
      _dismissForegroundAlert,
    );
  }

  void _dismissForegroundAlert() {
    _foregroundAlertTimer?.cancel();
    _foregroundAlertTimer = null;
    _foregroundAlertEntry?.remove();
    _foregroundAlertEntry = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final app = _app ?? context.read<AppController>();
    // C31: track foreground/background so the keep-alive path only raises a
    // system notification when the UI isn't already showing the message.
    app.setForeground(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    if (state == AppLifecycleState.resumed) {
      // C20: one entry point — reconnect if needed + lightweight catch-up.
      // C22: this resume → catchUp is also the post-FCM-wake correctness path.
      app.onResume();
      unawaited(_push?.start() ?? Future<void>.value());
      // Refresh the Android 13+ notification-permission diagnostic on resume.
      unawaited(_push?.refreshNotificationPermission() ?? Future<void>.value());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _app?.pendingOpenChat.removeListener(_onOpenChatRequested);
    unawaited(_foregroundAlertSub?.cancel());
    _dismissForegroundAlert();
    _pushRetryTimer?.cancel();
    IncomingShareService.latest.removeListener(_onIncomingShare);
    WidgetsBinding.instance.removeObserver(this);
    _searchRequests.dispose();
    super.dispose();
  }

  void _openSettings() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final tablet = MediaQuery.sizeOf(context).width >= _tabletBreakpoint;
    final theme = context.watch<ThemeController>();
    final glass = theme.useLiquidGlass;
    final inkWash = theme.useBlackWhite;
    final glassBg = liquidGlassPageColor(context);
    final headerBg = glass
        ? glassBg
        : inkWash
        ? scheme.surface
        : _homeAccent1_100(scheme);
    final pageBg = glass
        ? glassBg
        : inkWash
        ? scheme.surface
        : _homeAccent1_50(scheme);
    final chats = ConnectionNoticeHost(
      child: ChatsPane(
        searchRequests: _searchRequests,
        onSearchRequested: () => _searchRequests.value++,
        onOpenSettings: _openSettings,
      ),
    );
    return KeyboardInsetGuard(
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        backgroundColor: pageBg,
        appBar: tablet
            ? null
            : AppBar(
                centerTitle: true,
                backgroundColor: headerBg,
                surfaceTintColor: Colors.transparent,
                leading: IconButton(
                  tooltip: MicaLocalizations.of(context).t('chat.search'),
                  icon: const Icon(Icons.search),
                  onPressed: () => _searchRequests.value++,
                ),
                title: const Text('micaGO'),
                actions: [
                  IconButton(
                    tooltip: strings.t('nav.settings'),
                    icon: const Icon(Icons.settings_outlined),
                    onPressed: _openSettings,
                  ),
                ],
              ),
        body: tablet
            ? SafeArea(bottom: false, child: chats)
            : DecoratedBox(
                decoration: BoxDecoration(color: headerBg),
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(24),
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: pageBg),
                    child: SafeArea(top: false, bottom: false, child: chats),
                  ),
                ),
              ),
      ),
    );
  }
}

class _InAppMessageNotification extends StatelessWidget {
  final ForegroundMessageAlert alert;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  const _InAppMessageNotification({
    required this.alert,
    required this.onTap,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // C75: sit at the very top, overlaying the title bar. The status-bar inset
    // was previously applied twice (this offset AND a SafeArea below), which
    // pushed the card down under the app bar.
    final top = MediaQuery.paddingOf(context).top + 6;
    final body = (alert.body ?? '').trim();
    return Positioned(
      top: top,
      left: 12,
      right: 12,
      child: Material(
          color: Colors.transparent,
          child: Dismissible(
            key: ValueKey(
              'in-app-alert-${alert.messageGuid}-${alert.chatGuid}',
            ),
            direction: DismissDirection.up,
            onDismissed: (_) => onDismiss(),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: -18, end: 0),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              builder: (context, dy, child) => Transform.translate(
                offset: Offset(0, dy),
                child: Opacity(opacity: (18 + dy) / 18, child: child),
              ),
              child: Card(
                elevation: 8,
                shadowColor: Colors.black.withValues(alpha: 0.18),
                color: scheme.surfaceContainerHigh,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onTap,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        HandleAvatar(
                          title: alert.title,
                          handle: alert.isGroup ? null : alert.handle,
                          isGroup: alert.isGroup,
                          radius: 22,
                          localAvatarPath: alert.avatarFilePath,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                alert.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                body.isEmpty ? 'New message' : body,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: 'Dismiss',
                          onPressed: onDismiss,
                          icon: const Icon(Icons.close),
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

Color _homeAccent1_50(ColorScheme scheme) =>
    Color.alphaBlend(scheme.primary.withValues(alpha: 0.10), scheme.surface);

Color _homeAccent1_100(ColorScheme scheme) => Color.alphaBlend(
  scheme.primary.withValues(alpha: 0.18),
  scheme.surfaceContainerLowest,
);
