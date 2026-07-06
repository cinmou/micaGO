import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/network/connection_notice.dart';
import '../../core/ui/top_banner.dart';

/// Surfaces [AppController.connectionNotice] as the user-visible connection
/// feedback (C19): a sticky banner while offline / on the public fallback, and
/// a transient snackbar for recoveries. De-dup happens in the controller's
/// pure derivation, so this never spams.
class ConnectionNoticeHost extends StatefulWidget {
  final Widget child;
  const ConnectionNoticeHost({super.key, required this.child});

  @override
  State<ConnectionNoticeHost> createState() => _ConnectionNoticeHostState();
}

class _ConnectionNoticeHostState extends State<ConnectionNoticeHost> {
  AppController? _app;
  ConnectionNotice? _sticky;

  bool _cannotConnectDialogOpen = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = context.read<AppController>();
    if (identical(app, _app)) return;
    _app?.connectionNotice.removeListener(_onNotice);
    _app?.connectionHealthy.removeListener(_onHealthy);
    _app?.initialConnectFailed.removeListener(_onInitialConnectFailed);
    _app = app;
    app.connectionNotice.addListener(_onNotice);
    app.connectionHealthy.addListener(_onHealthy);
    app.initialConnectFailed.addListener(_onInitialConnectFailed);
  }

  @override
  void dispose() {
    _app?.connectionNotice.removeListener(_onNotice);
    _app?.connectionHealthy.removeListener(_onHealthy);
    _app?.initialConnectFailed.removeListener(_onInitialConnectFailed);
    super.dispose();
  }

  /// C29b: when the initial connection can't reach any server in 10s, show ONE
  /// clear dialog explaining the failure (not an endless "Reconnecting…"). If the
  /// connection later succeeds the flag clears and we auto-dismiss the dialog.
  void _onInitialConnectFailed() {
    final failed = _app?.initialConnectFailed.value ?? false;
    if (failed && !_cannotConnectDialogOpen) {
      _showCannotConnectDialog();
    } else if (!failed && _cannotConnectDialogOpen) {
      if (mounted) Navigator.of(context, rootNavigator: true).maybePop();
    }
  }

  Future<void> _showCannotConnectDialog() async {
    _cannotConnectDialogOpen = true;
    final strings = MicaLocalizations.of(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.cloud_off),
        title: Text(strings.t('connection.cannotReachTitle')),
        content: Text(strings.t('connection.cannotReachBody')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(strings.t('common.dismiss')),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _app?.retryInitialConnect();
            },
            child: Text(strings.t('common.retry')),
          ),
        ],
      ),
    );
    _cannotConnectDialogOpen = false;
  }

  /// C26: a healthy (connected) connection must never leave a stale problem
  /// banner up. Clearing here covers the connecting→connected edge that the
  /// one-shot notice derivation intentionally reports as null.
  void _onHealthy() {
    if (_app?.connectionHealthy.value == true && _sticky != null) {
      setState(() => _sticky = null);
    }
  }

  void _onNotice() {
    final notice = _app?.connectionNotice.value;
    if (notice == null) return;
    final message = MicaLocalizations.of(context).t(notice.l10nKey);

    if (notice.isTransient) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // C21u: surface recoveries/fallback switches as a top banner, not a
        // bottom snackbar.
        TopBanner.show(
          context,
          message,
          kind: notice.isProblem ? TopBannerKind.error : TopBannerKind.info,
          duration: const Duration(seconds: 2),
        );
      });
    }
    // Never raise a sticky problem banner while the connection is actually
    // healthy — a late/stale problem notice must not override a live connection.
    final healthy = _app?.connectionHealthy.value == true;
    setState(() => _sticky = (notice.isProblem && !healthy) ? notice : null);
    // Consume the one-shot so the same transition isn't re-handled.
    _app?.connectionNotice.value = null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sticky = _sticky;
    final strings = MicaLocalizations.of(context);
    return Column(
      children: [
        if (sticky != null)
          Material(
            color: scheme.errorContainer,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.cloud_off,
                      size: 16,
                      color: scheme.onErrorContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        strings.t(sticky.l10nKey),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Expanded(child: widget.child),
      ],
    );
  }
}
