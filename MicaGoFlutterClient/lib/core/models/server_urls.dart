/// Advertised routes consumed by the client endpoint selector.
class ServerEndpoint {
  final String baseUrl;
  final String wsUrl;
  final bool hidden;
  final bool enabled;
  final bool hasVisibilityFlags;

  const ServerEndpoint({
    required this.baseUrl,
    required this.wsUrl,
    this.hidden = false,
    this.enabled = true,
    this.hasVisibilityFlags = false,
  });

  bool get isVisible => enabled && !hidden;

  factory ServerEndpoint.fromJson(Map<String, dynamic> json) {
    return ServerEndpoint(
      hasVisibilityFlags: [
        'hidden',
        'isHidden',
        'disabled',
        'enabled',
      ].any(json.containsKey),
      baseUrl: (json['baseUrl'] as String?) ?? '',
      wsUrl: (json['wsUrl'] as String?) ?? '',
      hidden:
          _boolFlag(json['hidden']) ||
          _boolFlag(json['isHidden']) ||
          _boolFlag(json['disabled']),
      enabled: json.containsKey('enabled')
          ? _boolFlag(json['enabled'])
          : !_boolFlag(json['disabled']),
    );
  }
}

/// The optional public endpoint block.
class PublicEndpoint {
  final bool enabled;
  final String baseUrl;
  final String wsUrl;

  const PublicEndpoint({
    required this.enabled,
    required this.baseUrl,
    required this.wsUrl,
  });

  factory PublicEndpoint.fromJson(Map<String, dynamic> json) {
    return PublicEndpoint(
      enabled: (json['enabled'] as bool?) ?? false,
      baseUrl: (json['baseUrl'] as String?) ?? '',
      wsUrl: (json['wsUrl'] as String?) ?? '',
    );
  }
}

/// Top-level `GET /api/server/urls` response.
class ServerUrls {
  final List<ServerEndpoint> lan;
  final PublicEndpoint? public;

  /// C23: changes whenever the server's LAN/Public connection settings change,
  /// so the client can refresh candidates without rescanning.
  final String connectionRevision;

  const ServerUrls({
    required this.lan,
    required this.public,
    this.connectionRevision = '',
  });

  factory ServerUrls.fromJson(Map<String, dynamic> json) {
    List<ServerEndpoint> parseList(Object? raw) {
      if (raw is! List) return const [];
      return raw
          .whereType<Map<String, dynamic>>()
          .map(ServerEndpoint.fromJson)
          .toList(growable: false);
    }

    final publicRaw = json['public'];
    return ServerUrls(
      lan: parseList(json['lan']),
      public: publicRaw is Map<String, dynamic>
          ? PublicEndpoint.fromJson(publicRaw)
          : null,
      connectionRevision: (json['connectionRevision'] as String?) ?? '',
    );
  }
}

bool _boolFlag(Object? raw) {
  if (raw is bool) return raw;
  if (raw is num) return raw != 0;
  if (raw is String) {
    final v = raw.toLowerCase().trim();
    return v == 'true' || v == '1' || v == 'yes';
  }
  return false;
}
