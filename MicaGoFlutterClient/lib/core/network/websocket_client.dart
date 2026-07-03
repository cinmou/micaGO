import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'ws_channel_factory_io.dart'
    if (dart.library.html) 'ws_channel_factory_web.dart';

/// Lifecycle of the realtime WebSocket connection.
enum WsStatus { idle, connecting, connected, failed, disconnected }

/// One entry in the debug event log.
class WsLogEntry {
  final DateTime at;
  final String text;
  const WsLogEntry(this.at, this.text);
}

/// A parsed realtime event: `{ "type": "...", "data": { ... } }`.
class WsEvent {
  final String type;
  final Map<String, dynamic> data;
  const WsEvent(this.type, this.data);
}

/// Connects to the MicaGo `/ws` endpoint and surfaces connection state plus a
/// rolling debug log of received event names.
///
/// The connection is server→client push only (per the v0.9 contract); this
/// client only reads. Auth uses the `?token=` query parameter, which MicaGo
/// accepts alongside the `Authorization` header and works on every platform
/// (including web, where WebSocket headers cannot be set). The token is never
/// written to the log.
class WebSocketClient extends ChangeNotifier {
  static const int _maxLog = 200;

  WsStatus _status = WsStatus.idle;
  String? _lastError;
  DateTime? _lastEventAt;
  final List<WsLogEntry> _log = <WsLogEntry>[];

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  final StreamController<WsEvent> _events =
      StreamController<WsEvent>.broadcast();

  WsStatus get status => _status;
  String? get lastError => _lastError;
  DateTime? get lastEventAt => _lastEventAt;
  List<WsLogEntry> get log => List.unmodifiable(_log);

  /// Broadcast stream of parsed realtime events (e.g. `message:new`,
  /// `send:match`). Multiple listeners (thread, chat list) may subscribe.
  Stream<WsEvent> get events => _events.stream;

  /// Opens a connection to [wsUrl].
  ///
  /// Security (C55): on native platforms the token is sent in the
  /// `Authorization: Bearer` header (via `connectAuthedWebSocket`), so it never
  /// appears in the URL/logs. Web can't set WS headers, so it falls back to
  /// `?token=`. MicaGo's server accepts both.
  void connect(
    String wsUrl,
    String token, {
    Map<String, String> metadata = const {},
  }) {
    disconnect();

    final base = Uri.tryParse(wsUrl);
    if (base == null || (base.scheme != 'ws' && base.scheme != 'wss')) {
      _fail('Invalid WebSocket URL: $wsUrl');
      return;
    }

    _setStatus(WsStatus.connecting);
    _append('connecting…');

    try {
      final channel = connectAuthedWebSocket(base, token, metadata);
      _channel = channel;
      _sub = channel.stream.listen(
        _onData,
        onError: (Object error) => _fail('socket error: $error'),
        onDone: _onDone,
        cancelOnError: true,
      );
      // We're optimistic: connect() does not await the handshake. The first
      // frame (or onDone/onError) confirms the real state. Mark connected once
      // ready completes where supported.
      channel.ready
          .then((_) {
            if (_channel == channel) {
              _setStatus(WsStatus.connected);
              _append('connected');
            }
          })
          .catchError((Object error) {
            if (_channel == channel) _fail('handshake failed: $error');
          });
    } catch (e) {
      _fail('connect failed: $e');
    }
  }

  /// Closes the connection (if any) and resets to disconnected.
  void disconnect() {
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
    if (_status == WsStatus.connected || _status == WsStatus.connecting) {
      _setStatus(WsStatus.disconnected);
    }
  }

  void clearLog() {
    _log.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    _events.close();
    super.dispose();
  }

  // --- internals -------------------------------------------------------------

  void _onData(dynamic raw) {
    if (_status != WsStatus.connected) {
      _setStatus(WsStatus.connected);
    }
    String label;
    try {
      final decoded = jsonDecode(raw as String);
      if (decoded is Map<String, dynamic>) {
        final type = decoded['type'];
        label = type is String && type.isNotEmpty ? type : '(no type)';
        if (type is String && type.isNotEmpty && !_events.isClosed) {
          _lastEventAt = DateTime.now();
          final data = decoded['data'];
          _events.add(
            WsEvent(
              type,
              data is Map<String, dynamic> ? data : const <String, dynamic>{},
            ),
          );
        }
      } else {
        label = '(non-object frame)';
      }
    } catch (_) {
      label = '(unparseable frame)';
    }
    _append('event: $label');
  }

  void _onDone() {
    _append('closed');
    if (_status != WsStatus.failed) {
      _setStatus(WsStatus.disconnected);
    }
  }

  void _fail(String message) {
    _lastError = message;
    _append('error: $message');
    _setStatus(WsStatus.failed);
  }

  void _setStatus(WsStatus next) {
    if (_status == next) return;
    _status = next;
    notifyListeners();
  }

  void _append(String text) {
    _log.add(WsLogEntry(DateTime.now(), text));
    if (_log.length > _maxLog) {
      _log.removeRange(0, _log.length - _maxLog);
    }
    notifyListeners();
  }
}
