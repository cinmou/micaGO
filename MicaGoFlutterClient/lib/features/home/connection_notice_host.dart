import 'dart:async';

import '../../core/ui/app_dialog.dart';
import '../../core/ui/top_banner.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../../core/l10n/app_localizations.dart';

/// Connectivity is a quiet retry notice; rejected credentials require re-pairing.
class ConnectionNoticeHost extends StatefulWidget {
  final Widget child;
  const ConnectionNoticeHost({super.key, required this.child});

  @override
  State<ConnectionNoticeHost> createState() => _ConnectionNoticeHostState();
}

class _ConnectionNoticeHostState extends State<ConnectionNoticeHost> {
  AppController? _app;
  DialogRoute<void>? _noticeRoute;
  NavigatorState? _noticeNavigator;
  bool _retrying = false;

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
    if (!mounted) return;
    setState(() {});
    if (!(_app?.tokenRejected.value ?? false)) {
      final route = _noticeRoute;
      if (route != null && route.isActive) _noticeNavigator?.removeRoute(route);
      return;
    }
    TopBanner.dismiss();
    Navigator.of(
      context,
      rootNavigator: true,
    ).popUntil((route) => route == _noticeRoute || route.isFirst);
    if (_noticeRoute == null) unawaited(_showRejectedDialog());
  }

  Future<void> _showRejectedDialog() async {
    final strings = MicaLocalizations.of(context);
    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AppDialog(
          icon: const Icon(Icons.lock_outline),
          title: Text(strings.t('connection.tokenRejectedTitle')),
          content: Text(strings.t('connection.tokenRejectedBody')),
          confirmLabel: strings.t('connection.pairAgain'),
          onConfirm: () => Navigator.of(ctx).pop(),
        ),
      ),
    );
    _noticeRoute = route;
    _noticeNavigator = Navigator.of(context, rootNavigator: true);
    await _noticeNavigator!.push(route);
    if (identical(_noticeRoute, route)) _noticeRoute = null;
  }

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await _app?.retryInitialConnect();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final strings = MicaLocalizations.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (app.connectionProblemConfirmed.value && !app.tokenRejected.value)
          Positioned(
            top: MediaQuery.paddingOf(context).top + kToolbarHeight + 8,
            left: 12,
            right: 12,
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: AppNoticeCard(
                  message: strings.t('connection.serverUnavailable'),
                  actionLabel: strings.t('common.retry'),
                  onAction: _retrying ? null : _retry,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
