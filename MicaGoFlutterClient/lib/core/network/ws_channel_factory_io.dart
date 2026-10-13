import 'dart:async';

import 'secure_transport.dart';
import 'dart:io';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Native (dart:io) WebSocket connect. The bearer token travels in the
/// `Authorization` header — NOT in the URL — so it never leaks into server
/// access logs, reverse-proxy logs, or the Cloudflare tunnel's request logs
/// (C55). Only non-secret [metadata] goes in the query string.
WebSocketChannel connectAuthedWebSocket(
  Uri baseUri,
  String token,
  Map<String, String> metadata, [
  String? fingerprint,
  Duration handshakeTimeout = const Duration(seconds: 15),
]) {
  final uri = baseUri.replace(
    queryParameters: {...baseUri.queryParameters, ...metadata},
  );
  final headers = <String, dynamic>{};
  if (token.isNotEmpty) headers['Authorization'] = 'Bearer $token';
  final client = secureIoClient(uri.toString(), fingerprint: fingerprint);
  var timedOut = false;
  return IOWebSocketChannel(
    WebSocket.connect(
          uri.toString(),
          headers: headers.isEmpty ? null : headers,
          customClient: client,
        )
        .then((socket) {
          if (timedOut) {
            unawaited(socket.close());
          } else {
            socket.pingInterval = const Duration(seconds: 25);
          }
          return socket;
        })
        .timeout(
          handshakeTimeout,
          onTimeout: () {
            timedOut = true;
            // Future.timeout alone leaves the TLS/HTTP upgrade running. Abort
            // it so each retry cannot leave another stalled socket behind.
            client.close(force: true);
            throw TimeoutException(
              'WebSocket handshake timed out',
              handshakeTimeout,
            );
          },
        )
        .whenComplete(() => client.close()),
  );
}
