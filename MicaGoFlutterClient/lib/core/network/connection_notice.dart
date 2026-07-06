import 'connection_candidate.dart';
import 'websocket_client.dart';

/// User-facing connection events surfaced as a banner/snackbar (C19). Derived
/// purely from connection-state transitions so it is unit-testable and never
/// fires on steady state (no noisy repeated alerts).
enum ConnectionNotice {
  connected,
  reconnecting,
  disconnected,
  serverUnavailable,
  switchedToPublic,
  switchedToLan,
  webSocketLost,
  webSocketRecovered,
}

extension ConnectionNoticeDisplay on ConnectionNotice {
  String get l10nKey => switch (this) {
    ConnectionNotice.connected => 'connection.connected',
    ConnectionNotice.reconnecting => 'connection.reconnecting',
    ConnectionNotice.disconnected => 'connection.disconnected',
    ConnectionNotice.serverUnavailable => 'connection.serverUnavailable',
    ConnectionNotice.switchedToPublic => 'connection.switchedToPublic',
    ConnectionNotice.switchedToLan => 'connection.switchedToLan',
    ConnectionNotice.webSocketLost => 'connection.webSocketLost',
    ConnectionNotice.webSocketRecovered => 'connection.webSocketRecovered',
  };

  String get message => switch (this) {
    ConnectionNotice.connected => 'Connected',
    ConnectionNotice.reconnecting => 'Reconnecting…',
    ConnectionNotice.disconnected => 'Disconnected',
    ConnectionNotice.serverUnavailable =>
      'Server unavailable — check that it is running',
    ConnectionNotice.switchedToPublic =>
      'LAN unreachable — switched to the public address',
    ConnectionNotice.switchedToLan => 'Back on your local network (LAN)',
    ConnectionNotice.webSocketLost => 'Realtime updates lost — reconnecting',
    ConnectionNotice.webSocketRecovered => 'Realtime updates restored',
  };

  /// Transient (auto-dismiss snackbar) vs sticky (banner that stays until the
  /// state changes). Offline/unavailable stay visible; recoveries flash by.
  bool get isTransient => switch (this) {
    ConnectionNotice.connected => true,
    ConnectionNotice.switchedToLan => true,
    ConnectionNotice.webSocketRecovered => true,
    ConnectionNotice.reconnecting => false,
    ConnectionNotice.disconnected => false,
    ConnectionNotice.serverUnavailable => false,
    ConnectionNotice.switchedToPublic => false,
    ConnectionNotice.webSocketLost => false,
  };

  bool get isProblem => switch (this) {
    ConnectionNotice.disconnected => true,
    ConnectionNotice.serverUnavailable => true,
    ConnectionNotice.switchedToPublic => true,
    ConnectionNotice.webSocketLost => true,
    ConnectionNotice.reconnecting => true,
    _ => false,
  };
}

/// Immutable snapshot of the inputs the notice derivation looks at.
class ConnectionSnapshot {
  final WsStatus ws;
  final ConnectionCandidateKind? activeKind;
  final bool serverReachable;

  const ConnectionSnapshot({
    required this.ws,
    required this.activeKind,
    required this.serverReachable,
  });
}

/// Pure transition function: given the previous and current snapshot, returns
/// the single notice to surface, or null if nothing changed worth telling the
/// user. De-dup is the caller's job (don't re-show the same notice).
ConnectionNotice? connectionNoticeFor(
  ConnectionSnapshot? previous,
  ConnectionSnapshot current,
) {
  // No baseline yet: only announce a clearly-bad initial state, never a noisy
  // "connected" on first paint.
  if (previous == null) {
    if (!current.serverReachable) return ConnectionNotice.serverUnavailable;
    return null;
  }

  // Endpoint fallback takes priority — the user most needs to know they moved
  // off LAN onto the public path (or back).
  if (previous.activeKind != current.activeKind &&
      current.activeKind != null &&
      current.serverReachable) {
    if (current.activeKind == ConnectionCandidateKind.public) {
      return ConnectionNotice.switchedToPublic;
    }
    if (previous.activeKind == ConnectionCandidateKind.public) {
      return ConnectionNotice.switchedToLan;
    }
  }

  // Server reachability transitions.
  if (previous.serverReachable && !current.serverReachable) {
    return ConnectionNotice.serverUnavailable;
  }

  // WebSocket transitions (only meaningful while the server is reachable).
  final wasConnected = previous.ws == WsStatus.connected;
  final isConnected = current.ws == WsStatus.connected;
  if (wasConnected && !isConnected) {
    // A clean close is a plain disconnect; an error mid-session is "lost".
    return current.ws == WsStatus.disconnected
        ? ConnectionNotice.disconnected
        : ConnectionNotice.webSocketLost;
  }
  if (!wasConnected && isConnected) {
    // First connect is useful during manual pairing; routine realtime restore
    // is too noisy and is intentionally silent.
    return previous.ws == WsStatus.idle ? ConnectionNotice.connected : null;
  }
  if (!isConnected &&
      (current.ws == WsStatus.connecting || current.ws == WsStatus.failed) &&
      previous.ws != current.ws &&
      current.serverReachable) {
    return ConnectionNotice.reconnecting;
  }

  return null;
}
