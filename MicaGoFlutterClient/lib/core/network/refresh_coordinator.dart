import 'dart:async';
import 'dart:math';

import 'websocket_client.dart';

/// C20: the single source of truth for the *fallback* refresh tier — WebSocket
/// reconnection (with backoff) and conservative polling while the socket is
/// down. The realtime tier (targeted thread/chat-list patching from WS events)
/// and the catch-up-on-reconnect live in their controllers; this coordinator
/// only decides "when do we reconnect / poll because realtime isn't flowing".
///
/// Strategy (BlueBubbles-like): realtime first → targeted refresh second →
/// periodic/catch-up polling as the fallback. This class owns the third tier.
class RefreshCoordinator {
  /// Re-establish the connection (health-check + reselect endpoint + connect).
  final Future<void> Function() reconnect;

  /// Pull anything missed while realtime wasn't flowing.
  final Future<void> Function(String reason) catchUp;

  /// Live WebSocket status (so scheduled work can no-op once reconnected).
  final WsStatus Function() wsStatus;

  /// Conservative poll cadence while the socket is down. Injectable for tests.
  final Duration fallbackPollInterval;

  RefreshCoordinator({
    required this.reconnect,
    required this.catchUp,
    required this.wsStatus,
    this.fallbackPollInterval = const Duration(seconds: 20),
  });

  Timer? _reconnectTimer;
  Timer? _fallbackPoll;
  int _reconnectAttempt = 0;

  /// Whether a fallback poll is currently running (exposed for tests/diagnostics).
  bool get isPolling => _fallbackPoll != null;

  /// Drive the coordinator from WebSocket status changes.
  void onWsStatusChanged(WsStatus status) {
    switch (status) {
      case WsStatus.connected:
        _reconnectAttempt = 0;
        _cancelReconnect();
        _stopFallbackPoll();
        break;
      case WsStatus.disconnected:
      case WsStatus.failed:
        // Realtime is down: schedule a reconnect and start the fallback poll so
        // missed messages still arrive even if the socket can't be restored.
        _scheduleReconnect();
        _startFallbackPoll();
        break;
      case WsStatus.connecting:
      case WsStatus.idle:
        break;
    }
  }

  /// App returned to the foreground: reconnect promptly and do a light catch-up.
  Future<void>? _resume;
  Future<void> onResume() =>
      _resume ??= _resumeInner().whenComplete(() => _resume = null);

  Future<void> _resumeInner() async {
    if (wsStatus() != WsStatus.connected) await reconnect();
    await catchUp('resume');
  }

  void dispose() {
    _cancelReconnect();
    _stopFallbackPoll();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    final delay = reconnectBackoff(_reconnectAttempt);
    _reconnectAttempt++;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (wsStatus() != WsStatus.connected) unawaited(reconnect());
    });
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  void _startFallbackPoll() {
    if (_fallbackPoll != null) return; // already polling
    _fallbackPoll = Timer.periodic(fallbackPollInterval, (_) {
      if (wsStatus() == WsStatus.connected) {
        _stopFallbackPoll();
        return;
      }
      unawaited(catchUp('fallback_poll'));
    });
  }

  void _stopFallbackPoll() {
    _fallbackPoll?.cancel();
    _fallbackPoll = null;
  }
}

/// Exponential-ish reconnect backoff, capped. Pure + testable.
Duration reconnectBackoff(int attempt) {
  const schedule = [1, 2, 5, 10, 15];
  return Duration(seconds: schedule[min(attempt, schedule.length - 1)]);
}
