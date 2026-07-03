/// Models for `GET /api/server/urls` (MicaGo v0.11 connection endpoints).
///
/// Shape (camelCase per the v0.9 client API contract):
/// ```json
/// {
///   "local": [ { "kind", "label", "baseUrl", "wsUrl", "reachable" } ],
///   "lan":   [ { ... } ],
///   "public": { "enabled", "kind", "baseUrl", "wsUrl", "reachable",
///               "providerHint", "verifyTls", "lastCheckedAt" },
///   "preferredPairingEndpoint": "auto"
/// }
/// ```
library;

/// A single reachable endpoint entry (local or LAN).
class ServerEndpoint {
  final String kind;
  final String label;
  final String baseUrl;
  final String wsUrl;
  final bool hidden;
  final bool enabled;

  /// `reachable` is `true` / `false` / `"unknown"` on the wire; kept as the
  /// raw dynamic and exposed via [reachableLabel].
  final Object? reachable;

  const ServerEndpoint({
    required this.kind,
    required this.label,
    required this.baseUrl,
    required this.wsUrl,
    this.hidden = false,
    this.enabled = true,
    required this.reachable,
  });

  String get reachableLabel => _reachableLabel(reachable);
  bool get isVisible => enabled && !hidden;

  factory ServerEndpoint.fromJson(Map<String, dynamic> json) {
    return ServerEndpoint(
      kind: (json['kind'] as String?) ?? '',
      label: (json['label'] as String?) ?? '',
      baseUrl: (json['baseUrl'] as String?) ?? '',
      wsUrl: (json['wsUrl'] as String?) ?? '',
      hidden:
          _boolFlag(json['hidden']) ||
          _boolFlag(json['isHidden']) ||
          _boolFlag(json['disabled']),
      enabled: json.containsKey('enabled')
          ? _boolFlag(json['enabled'])
          : !_boolFlag(json['disabled']),
      reachable: json['reachable'],
    );
  }
}

/// The optional public endpoint block.
class PublicEndpoint {
  final bool enabled;
  final String kind;
  final String baseUrl;
  final String wsUrl;
  final Object? reachable;
  final String? providerHint;
  final bool verifyTls;
  final int? lastCheckedAt;

  const PublicEndpoint({
    required this.enabled,
    required this.kind,
    required this.baseUrl,
    required this.wsUrl,
    required this.reachable,
    required this.providerHint,
    required this.verifyTls,
    required this.lastCheckedAt,
  });

  String get reachableLabel => _reachableLabel(reachable);

  factory PublicEndpoint.fromJson(Map<String, dynamic> json) {
    return PublicEndpoint(
      enabled: (json['enabled'] as bool?) ?? false,
      kind: (json['kind'] as String?) ?? '',
      baseUrl: (json['baseUrl'] as String?) ?? '',
      wsUrl: (json['wsUrl'] as String?) ?? '',
      reachable: json['reachable'],
      providerHint: json['providerHint'] as String?,
      verifyTls: (json['verifyTls'] as bool?) ?? true,
      lastCheckedAt: (json['lastCheckedAt'] as num?)?.toInt(),
    );
  }
}

/// Top-level `GET /api/server/urls` response.
class ServerUrls {
  // C25: loopback/local is no longer part of the connection flow — the only
  // client-usable endpoints are LAN and the optional Public.
  final List<ServerEndpoint> lan;
  final PublicEndpoint? public;
  final String preferredPairingEndpoint;

  /// C23: changes whenever the server's LAN/Public connection settings change,
  /// so the client can refresh candidates without rescanning.
  final String connectionRevision;

  const ServerUrls({
    required this.lan,
    required this.public,
    required this.preferredPairingEndpoint,
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
      preferredPairingEndpoint:
          (json['preferredPairingEndpoint'] as String?) ?? 'auto',
      connectionRevision: (json['connectionRevision'] as String?) ?? '',
    );
  }
}

String _reachableLabel(Object? reachable) {
  if (reachable is bool) return reachable ? 'reachable' : 'unreachable';
  return 'unknown';
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
