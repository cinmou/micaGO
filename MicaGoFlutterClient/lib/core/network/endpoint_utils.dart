/// URL helpers shared by the REST and WebSocket clients.
///
/// MicaGo serves REST under `/api` and a plain WebSocket at `/ws`. These helpers
/// normalise user-entered base URLs and derive the matching ws/wss URL.
library;

/// Normalises a user-entered server base URL:
/// - trims surrounding whitespace,
/// - defaults to `http://` when no scheme is present,
/// - removes any trailing slash.
///
/// Returns an empty string for empty input. It does not validate reachability.
///
/// The result is a **bare origin** (`scheme://host[:port]`): any path, query,
/// or fragment is dropped so request paths like `/api/health` are appended
/// exactly once (avoids `…/api/api/health` from a pasted URL).
String normalizeBaseUrl(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return '';
  if (!value.contains('://')) {
    value = 'http://$value';
  }

  final uri = Uri.tryParse(value);
  if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port';
  }

  // Fallback for unparseable input: just strip trailing slashes.
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

/// Derives the WebSocket URL for the `/ws` endpoint from an http(s) base URL:
/// `http` → `ws`, `https` → `wss`, then appends `/ws` (unless the base already
/// ends in `/ws`).
///
/// Falls back to returning the input unchanged if it cannot be parsed.
String deriveWebSocketUrl(String baseUrl) {
  final normalized = normalizeBaseUrl(baseUrl);
  if (normalized.isEmpty) return '';

  final uri = Uri.tryParse(normalized);
  if (uri == null) return normalized;

  final scheme = switch (uri.scheme) {
    'https' => 'wss',
    'http' => 'ws',
    'wss' => 'wss',
    'ws' => 'ws',
    _ => 'ws',
  };

  var path = uri.path;
  if (!path.endsWith('/ws')) {
    if (path.endsWith('/')) {
      path = '${path}ws';
    } else {
      path = '$path/ws';
    }
  }

  return uri.replace(scheme: scheme, path: path).toString();
}

/// Returns true when [value] parses to an absolute http(s) URL with a host.
bool isValidHttpUrl(String value) {
  final uri = Uri.tryParse(normalizeBaseUrl(value));
  if (uri == null) return false;
  return uri.hasScheme &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}

/// Resolve WebSocket ports through the corresponding HTTP scheme. Dart's Uri
/// only supplies default ports for HTTP/HTTPS, not WS/WSS.
int transportPort(Uri uri) => switch (uri.scheme) {
  'wss' => uri.replace(scheme: 'https').port,
  'ws' => uri.replace(scheme: 'http').port,
  _ => uri.port,
};

/// REST and WebSocket routes must share the same secure host and port.
bool isSecureEndpointPair(String baseUrl, String wsUrl) {
  final base = Uri.tryParse(baseUrl);
  final ws = Uri.tryParse(wsUrl);
  return base != null &&
      ws != null &&
      base.scheme == 'https' &&
      ws.scheme == 'wss' &&
      base.host.isNotEmpty &&
      base.host == ws.host &&
      transportPort(base) == transportPort(ws);
}
