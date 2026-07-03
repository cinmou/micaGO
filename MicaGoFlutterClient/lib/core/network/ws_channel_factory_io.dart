import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Native (dart:io) WebSocket connect. The bearer token travels in the
/// `Authorization` header — NOT in the URL — so it never leaks into server
/// access logs, reverse-proxy logs, or the Cloudflare tunnel's request logs
/// (C55). Only non-secret [metadata] goes in the query string.
WebSocketChannel connectAuthedWebSocket(
  Uri baseUri,
  String token,
  Map<String, String> metadata,
) {
  final uri = baseUri.replace(
    queryParameters: {...baseUri.queryParameters, ...metadata},
  );
  final headers = <String, dynamic>{};
  if (token.isNotEmpty) headers['Authorization'] = 'Bearer $token';
  return IOWebSocketChannel.connect(
    uri,
    headers: headers.isEmpty ? null : headers,
  );
}
