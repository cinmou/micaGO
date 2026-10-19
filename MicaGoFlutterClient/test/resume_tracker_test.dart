import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/platform/resume_tracker.dart';

void main() {
  test('permission dialog and hidden overlay are focus returns on mobile', () {
    final tracker = ResumeTracker();
    expect(tracker.update(AppLifecycleState.inactive), ResumeTransition.none);
    expect(tracker.update(AppLifecycleState.hidden), ResumeTransition.none);
    expect(
      tracker.update(AppLifecycleState.resumed),
      ResumeTransition.focusReturned,
    );
    expect(tracker.update(AppLifecycleState.resumed), ResumeTransition.none);
  });
  test('camera or lock-screen pause is recorded until resume', () {
    final tracker = ResumeTracker();
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
    ]) {
      tracker.update(state);
    }
    expect(
      tracker.update(AppLifecycleState.resumed),
      ResumeTransition.backgroundReturned,
    );
    tracker.update(AppLifecycleState.inactive);
    expect(
      tracker.update(AppLifecycleState.resumed),
      ResumeTransition.focusReturned,
    );
  });
  test('minimized desktop without a paused event is a background return', () {
    final tracker = ResumeTracker(hiddenIsBackground: true);
    tracker.update(AppLifecycleState.hidden);
    expect(
      tracker.update(AppLifecycleState.resumed),
      ResumeTransition.backgroundReturned,
    );
  });
}
