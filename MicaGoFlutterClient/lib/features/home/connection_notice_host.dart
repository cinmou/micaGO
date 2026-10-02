import '../../core/ui/app_dialog.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../../core/l10n/app_localizations.dart';

/// One app-wide notice surface. Authentication rejection takes priority over
/// connectivity failures, including while a timeout dialog is already open.
class ConnectionNoticeHost extends StatefulWidget {
  final Widget child;
  const ConnectionNoticeHost({super.key, required this.child});

  @override
  State<ConnectionNoticeHost> createState() => _ConnectionNoticeHostState();
}

class _ConnectionNoticeHostState extends State<ConnectionNoticeHost> {
  AppController? _app;
  bool _dialogOpen = false;
  DialogRoute<void>? _noticeRoute;
  NavigatorState? _noticeNavigator;

  /// Connectivity failures may leave a retry strip after the dialog closes.
  /// Rejected credentials are explained only by the dialog.
  bool _showStickyBanner = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = context.read<AppController>();
    if (identical(app, _app)) return;
    _app?.connectionProblemConfirmed.removeListener(_onProblemChanged);
    _app?.tokenRejected.removeListener(_onProblemChanged);
    _app = app;
    app.connectionProblemConfirmed.addListener(_onProblemChanged);
    app.tokenRejected.addListener(_onProblemChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onProblemChanged();
    });
  }

  @override
  void dispose() {
    _app?.connectionProblemConfirmed.removeListener(_onProblemChanged);
    _app?.tokenRejected.removeListener(_onProblemChanged);
    super.dispose();
  }

  void _onProblemChanged() {
    final problem =
        (_app?.tokenRejected.value ?? false) ||
        (_app?.connectionProblemConfirmed.value ?? false);
    if (!problem) {
      // Recovered: drop the banner and close the dialog if it is still up.
      if (_showStickyBanner && mounted) {
        setState(() => _showStickyBanner = false);
      }
      if (_dialogOpen && mounted) {
        final route = _noticeRoute;
        if (route != null && route.isActive) {
          _noticeNavigator?.removeRoute(route);
        }
      }
      return;
    }
    if (_app?.tokenRejected.value ?? false) {
      ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
      // Remove unrelated pageless routes that could still show old records.
      Navigator.of(
        context,
        rootNavigator: true,
      ).popUntil((route) => route == _noticeRoute || route.isFirst);
    }
    if (!_dialogOpen) {
      if (_showStickyBanner && mounted) {
        setState(() => _showStickyBanner = false);
      }
      unawaitedShowDialog();
    }
  }

  void unawaitedShowDialog() {
    // Fire and forget — the dialog's own future flips the sticky banner on.
    _showCannotConnectDialog();
  }

  Future<void> _showCannotConnectDialog() async {
    _dialogOpen = true;
    final strings = MicaLocalizations.of(context);
    final route = DialogRoute<void>(
      context: context,
      builder: (ctx) => ValueListenableBuilder<bool>(
        valueListenable: _app!.tokenRejected,
        builder: (context, rejected, _) => PopScope(
          canPop: !rejected,
          child: AppDialog(
            icon: Icon(rejected ? Icons.lock_outline : Icons.cloud_off),
            title: Text(
              strings.t(
                rejected
                    ? 'connection.tokenRejectedTitle'
                    : 'connection.cannotReachTitle',
              ),
            ),
            content: Text(
              strings.t(
                rejected
                    ? 'connection.tokenRejectedBody'
                    : 'connection.cannotReachBody',
              ),
            ),
            cancelLabel: rejected ? null : strings.t('common.dismiss'),
            onCancel: rejected ? null : () => Navigator.of(ctx).pop(),
            confirmLabel: strings.t(
              rejected ? 'connection.pairAgain' : 'common.retry',
            ),
            onConfirm: () {
              Navigator.of(ctx).pop();
              if (!rejected) _app?.retryInitialConnect();
            },
          ),
        ),
      ),
    );
    _noticeRoute = route;
    _noticeNavigator = Navigator.of(context, rootNavigator: true);
    await _noticeNavigator!.push(route);
    _noticeRoute = null;
    _dialogOpen = false;
    if (!mounted) return;
    // The banner takes over from the dialog, and only while still broken.
    final stillBroken =
        !(_app?.tokenRejected.value ?? false) &&
        (_app?.connectionProblemConfirmed.value ?? false);
    setState(() => _showStickyBanner = stillBroken);
  }

  @override
  Widget build(BuildContext context) {
    final rejected = context.watch<AppController>().tokenRejected.value;
    final scheme = Theme.of(context).colorScheme;
    final strings = MicaLocalizations.of(context);
    return Column(
      children: [
        if (_showStickyBanner && !rejected)
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
                        strings.t('connection.serverUnavailable'),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onErrorContainer,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _app?.retryInitialConnect(),
                      child: Text(strings.t('common.retry')),
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
