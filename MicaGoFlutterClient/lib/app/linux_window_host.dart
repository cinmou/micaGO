import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../core/app_controller.dart';
import '../core/platform/linux_desktop.dart';

/// Both native windows use one engine and the same application controllers.
class LinuxWindowHost extends StatefulWidget {
  const LinuxWindowHost({
    super.key,
    required this.controller,
    required this.mainApp,
    required this.settingsApp,
  });

  final AppController controller;
  final Widget mainApp;
  final Widget settingsApp;

  @override
  State<LinuxWindowHost> createState() => _LinuxWindowHostState();
}

class _LinuxWindowHostState extends State<LinuxWindowHost>
    with WidgetsBindingObserver {
  int? _focusedViewId;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    LinuxDesktop.attachWindowFocusHandler(_handleWindowFocus);
    widget.controller.addListener(_checkSession);
  }

  void _handleWindowFocus(ui.ViewFocusEvent event) {
    if (event.state == ui.ViewFocusState.focused) {
      _focusedViewId = event.viewId;
    } else if (_focusedViewId == event.viewId) {
      _focusedViewId = null;
    }
    final binding = WidgetsBinding.instance;
    binding.handleViewFocusChanged(event);
    if (_focusedViewId != null) {
      scheduleMicrotask(_restoreFocusedView);
    } else if (binding.lifecycleState == AppLifecycleState.resumed) {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    }
  }

  // The Linux embedder's lifecycle monitor follows the main GTK window. Keep
  // the app active while the settings window owns focus, and restore its scope.
  void _restoreFocusedView() {
    final viewId = _focusedViewId;
    if (!mounted ||
        viewId == null ||
        !ui.PlatformDispatcher.instance.views.any(
          (view) => view.viewId == viewId,
        )) {
      return;
    }
    final binding = WidgetsBinding.instance;
    if (binding.lifecycleState != AppLifecycleState.resumed) {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
    binding.handleViewFocusChanged(
      ui.ViewFocusEvent(
        viewId: viewId,
        state: ui.ViewFocusState.focused,
        direction: ui.ViewFocusDirection.undefined,
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _focusedViewId != null) {
      scheduleMicrotask(_restoreFocusedView);
    }
  }

  void _checkSession() {
    if (widget.controller.hasProfile &&
        !widget.controller.tokenRejected.value) {
      return;
    }
    if (ui.PlatformDispatcher.instance.views.length > 1) {
      unawaited(LinuxDesktop.closeSettings());
    }
  }

  @override
  void didChangeMetrics() {
    if (!ui.PlatformDispatcher.instance.views.any(
      (view) => view.viewId == _focusedViewId,
    )) {
      _focusedViewId = null;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    LinuxDesktop.detachWindowFocusHandler();
    widget.controller.removeListener(_checkSession);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dispatcher = ui.PlatformDispatcher.instance;
    return ViewCollection(
      views: [
        for (final view in dispatcher.views)
          View(
            key: ValueKey(view.viewId),
            view: view,
            child: view.viewId == dispatcher.implicitView?.viewId
                ? widget.mainApp
                : widget.settingsApp,
          ),
      ],
    );
  }
}
