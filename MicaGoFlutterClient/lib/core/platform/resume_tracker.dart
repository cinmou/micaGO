import 'package:flutter/widgets.dart';

/// Losing input focus to a permission dialog is different from leaving the app.
/// Mirrors BlueBubbles' paused/detached distinction without coupling transport
/// to any one camera, file picker or permission plugin.
enum ResumeTransition { none, focusReturned, backgroundReturned }

class ResumeTracker {
  ResumeTracker({this.hiddenIsBackground = false});
  final bool hiddenIsBackground;
  AppLifecycleState _previous = AppLifecycleState.resumed;
  bool _backgrounded = false;

  ResumeTransition update(AppLifecycleState state) {
    if (state == _previous) return ResumeTransition.none;
    _previous = state;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        (hiddenIsBackground && state == AppLifecycleState.hidden)) {
      _backgrounded = true;
    }
    if (state != AppLifecycleState.resumed) return ResumeTransition.none;
    final result = _backgrounded
        ? ResumeTransition.backgroundReturned
        : ResumeTransition.focusReturned;
    _backgrounded = false;
    return result;
  }
}
