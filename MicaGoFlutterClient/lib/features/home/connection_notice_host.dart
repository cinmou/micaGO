import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../../core/l10n/app_localizations.dart';

/// C75: the single surface for connection trouble.
///
/// Previously three surfaces fought each other — a transient top banner, a
/// sticky red banner, and a modal dialog — and the banner could appear the
/// moment you opened the app, before the first connect had a chance to finish.
///
/// Now there is one signal ([AppController.connectionProblemConfirmed], set
/// only after the link has been down for 10 continuous seconds) and one
/// sequence: **dialog first, then the sticky banner stays** until the
/// connection recovers. Recovery clears both immediately. Transient
/// connection banners are gone entirely.
class ConnectionNoticeHost extends StatefulWidget {
  final Widget child;
  const ConnectionNoticeHost({super.key, required this.child});

  @override
  State<ConnectionNoticeHost> createState() => _ConnectionNoticeHostState();
}

class _ConnectionNoticeHostState extends State<ConnectionNoticeHost> {
  AppController? _app;
  bool _dialogOpen = false;

  /// The sticky banner only appears once the dialog has been presented, so the
  /// user always gets the explanation before the persistent strip.
  bool _showStickyBanner = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = context.read<AppController>();
    if (identical(app, _app)) return;
    _app?.connectionProblemConfirmed.removeListener(_onProblemChanged);
    _app = app;
    app.connectionProblemConfirmed.addListener(_onProblemChanged);
  }

  @override
  void dispose() {
    _app?.connectionProblemConfirmed.removeListener(_onProblemChanged);
    super.dispose();
  }

  void _onProblemChanged() {
    final problem = _app?.connectionProblemConfirmed.value ?? false;
    if (!problem) {
      // Recovered: drop the banner and close the dialog if it is still up.
      if (_showStickyBanner && mounted) {
        setState(() => _showStickyBanner = false);
      }
      if (_dialogOpen && mounted) {
        Navigator.of(context, rootNavigator: true).maybePop();
      }
      return;
    }
    if (!_dialogOpen) unawaitedShowDialog();
  }

  void unawaitedShowDialog() {
    // Fire and forget — the dialog's own future flips the sticky banner on.
    _showCannotConnectDialog();
  }

  Future<void> _showCannotConnectDialog() async {
    _dialogOpen = true;
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
    _dialogOpen = false;
    if (!mounted) return;
    // The banner takes over from the dialog, and only while still broken.
    final stillBroken = _app?.connectionProblemConfirmed.value ?? false;
    setState(() => _showStickyBanner = stillBroken);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final strings = MicaLocalizations.of(context);
    return Column(
      children: [
        if (_showStickyBanner)
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
