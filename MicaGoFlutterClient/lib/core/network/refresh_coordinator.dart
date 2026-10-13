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

  /// Authenticated liveness probe for a retained foreground socket.
  final Future<bool> Function()? checkConnection;

  /// Conservative poll cadence while the socket is down. Injectable for tests.
  final Duration fallbackPollInterval;

  RefreshCoordinator({
    required this.reconnect,
    required this.catchUp,
    required this.wsStatus,
    this.checkConnection,
    this.fallbackPollInterval = const Duration(seconds: 20),
  });

  Timer? _reconnectTimer;
  Timer? _fallbackPoll;
  int _reconnectAttempt = 0;
  int _generation = 0;
  Future<void>? _reconnecting;

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
        _cancelReconnect();
        break;
      case WsStatus.idle:
        break;
    }
  }

  /// App returned to the foreground: reconnect promptly and do a light catch-up.
  Future<void>? _resume;
  Future<void> onResume({bool wasBackgrounded = true}) => _resume ??=
      _resumeInner(wasBackgrounded).whenComplete(() => _resume = null);

  Future<void> _resumeInner(bool wasBackgrounded) async {
    final generation = _generation;
    var status = wsStatus();
    var attemptedReconnect = false;
    // Permission dialogs and short focus changes do not replace a healthy socket.
    if (!wasBackgrounded && status == WsStatus.connected) return;
    if (wasBackgrounded &&
        status == WsStatus.connected &&
        checkConnection != null) {
      final alive = await checkConnection!();
      if (generation != _generation) return;
      status = wsStatus();
      if (!alive && status == WsStatus.connected) {
        _cancelReconnect();
        attemptedReconnect = true;
        await _reconnect();
      }
    }
    if (generation != _generation) return;
    status = wsStatus();
    if (!attemptedReconnect &&
        status != WsStatus.connected &&
        status != WsStatus.connecting) {
      _cancelReconnect();
      await _reconnect();
    }
    if (generation == _generation) await catchUp('resume');
  }

  void dispose() {
    _generation++;
    _cancelReconnect();
    _stopFallbackPoll();
  }

  void _scheduleReconnect() {
    if (_reconnectTimer != null || _reconnecting != null) return;
    final delay = reconnectBackoff(_reconnectAttempt);
    _reconnectAttempt++;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (wsStatus() == WsStatus.failed ||
          wsStatus() == WsStatus.disconnected) {
        // Endpoint probes may fail without changing the socket status. Keep
        // retrying with backoff, but never overlap a probe or handshake.
        unawaited(_reconnect().catchError((Object _) {}));
      }
    });
  }

  Future<void> _reconnect() {
    final pending = _reconnecting;
    if (pending != null) return pending;
    final generation = _generation;
    late final Future<void> attempt;
    attempt = Future<void>.sync(reconnect).whenComplete(() {
      if (identical(_reconnecting, attempt)) _reconnecting = null;
      if (generation == _generation &&
          (wsStatus() == WsStatus.failed ||
              wsStatus() == WsStatus.disconnected)) {
        _scheduleReconnect();
      }
    });
    _reconnecting = attempt;
    return attempt;
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
