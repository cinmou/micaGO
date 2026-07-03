import 'package:web_socket_channel/web_socket_channel.dart';

/// Web fallback: browsers can't set custom headers on a WebSocket handshake, so
/// the token has to go in the query string here. (Native platforms use the
/// Authorization header — see ws_channel_factory_io.dart — C55.)
WebSocketChannel connectAuthedWebSocket(
  Uri baseUri,
  String token,
  Map<String, String> metadata,
) {
  final uri = baseUri.replace(
    queryParameters: {
      ...baseUri.queryParameters,
      if (token.isNotEmpty) 'token': token,
      ...metadata,
    },
  );
  return WebSocketChannel.connect(uri);
}
