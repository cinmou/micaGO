import '../network/endpoint_utils.dart';

enum ConnectionMode { auto, lanOnly, publicOnly, lanFirst }

ConnectionMode connectionModeFromWire(String? value) {
  switch (value) {
    case 'lan_only':
      return ConnectionMode.lanOnly;
    case 'public_only':
      return ConnectionMode.publicOnly;
    case 'lan_first':
      return ConnectionMode.lanFirst;
    default:
      return ConnectionMode.auto;
  }
}

String connectionModeToWire(ConnectionMode mode) {
  switch (mode) {
    case ConnectionMode.lanOnly:
      return 'lan_only';
    case ConnectionMode.publicOnly:
      return 'public_only';
    case ConnectionMode.lanFirst:
      return 'lan_first';
    case ConnectionMode.auto:
      return 'auto';
  }
}

/// One concrete endpoint (base + websocket URL). C26: the server can expose
/// several LAN interface addresses, so a profile keeps the full list rather than
/// assuming the first discovered interface is the right route.
class EndpointRef {
  final String baseUrl;
  final String wsUrl;
  const EndpointRef({required this.baseUrl, required this.wsUrl});

  Map<String, dynamic> toJson() => {'baseUrl': baseUrl, 'wsUrl': wsUrl};

  factory EndpointRef.fromJson(Map<String, dynamic> json) => EndpointRef(
    baseUrl: (json['baseUrl'] as String?)?.trim() ?? '',
    wsUrl: (json['wsUrl'] as String?)?.trim() ?? '',
  );

  @override
  bool operator ==(Object other) =>
      other is EndpointRef && other.baseUrl == baseUrl && other.wsUrl == wsUrl;

  @override
  int get hashCode => Object.hash(baseUrl, wsUrl);
}

/// A saved MicaGo server connection. Persisted locally (token in secure
/// storage). The token is never included in `toString()` to avoid leaking it
/// into logs.
class ConnectionProfile {
  /// Normalised http(s) base URL, e.g. `https://mica.example.com`.
  final String baseUrl;

  /// Device-scoped bearer credential.
  final String token;
  final String tlsFingerprint;
  final String deviceId;
  final String? pairingCode;

  String? pinFor(String url) =>
      tlsFingerprint.isNotEmpty &&
          (lanRoutes.any(
                (r) => Uri.parse(r.baseUrl).origin == Uri.parse(url).origin,
              ) ||
              (baseUrl != publicBaseUrl &&
                  Uri.parse(baseUrl).origin == Uri.parse(url).origin))
      ? tlsFingerprint
      : null;

  /// Optional explicit WebSocket URL. When null/empty, [effectiveWsUrl] derives
  /// it from [baseUrl].
  final String? wsUrlOverride;

  /// All LAN candidates the server advertised (C26 multi-LAN). May hold several
  /// interface addresses; the user can pin one via [selectedBaseUrl].
  final List<EndpointRef> lanRoutes;

  /// The user's manually selected route base URL (LAN or Public), persisted so
  /// it survives refresh/restart. Null means "auto" (LAN-first). When set and
  /// still present in the candidate set, it is preferred for connect/reconnect.
  final String? selectedBaseUrl;

  final String? publicBaseUrl;
  final String? publicWsUrl;
  final ConnectionMode mode;

  /// C23: the server connection-config revision this profile was last synced to.
  /// Used to detect when the server's LAN/Public candidates change so the client
  /// can refresh them without rescanning a QR.
  final String configRevision;

  ConnectionProfile({
    required this.baseUrl,
    required this.token,
    this.tlsFingerprint = '',
    this.deviceId = '',
    this.pairingCode,
    this.wsUrlOverride,
    List<EndpointRef>? lanRoutes,
    String? lanBaseUrl,
    String? lanWsUrl,
    this.selectedBaseUrl,
    this.publicBaseUrl,
    this.publicWsUrl,
    this.mode = ConnectionMode.auto,
    this.configRevision = '',
  }) : lanRoutes = _seedLanRoutes(lanRoutes, lanBaseUrl, lanWsUrl);

  static List<EndpointRef> _seedLanRoutes(
    List<EndpointRef>? routes,
    String? lanBaseUrl,
    String? lanWsUrl,
  ) {
    if (routes != null && routes.isNotEmpty) {
      return List.unmodifiable(routes.where((r) => r.baseUrl.isNotEmpty));
    }
    final base = lanBaseUrl?.trim() ?? '';
    if (base.isEmpty) return const [];
    final ws = lanWsUrl?.trim() ?? '';
    return List.unmodifiable([
      EndpointRef(
        baseUrl: base,
        wsUrl: ws.isNotEmpty ? ws : deriveWebSocketUrl(base),
      ),
    ]);
  }

  /// The active LAN route: the user's pinned selection when it still exists,
  /// otherwise the first advertised LAN candidate.
  EndpointRef? get selectedLanRoute {
    if (lanRoutes.isEmpty) return null;
    final pinned = selectedBaseUrl;
    if (pinned != null && pinned.isNotEmpty) {
      for (final r in lanRoutes) {
        if (r.baseUrl == pinned) return r;
      }
    }
    return lanRoutes.first;
  }

  String? get lanBaseUrl => selectedLanRoute?.baseUrl;
  String? get lanWsUrl => selectedLanRoute?.wsUrl;

  /// Whether [selectedBaseUrl] pins the Public endpoint.
  bool get publicIsSelected =>
      selectedBaseUrl != null &&
      selectedBaseUrl!.isNotEmpty &&
      selectedBaseUrl == _nonEmpty(publicBaseUrl);

  String get effectiveBaseUrl {
    switch (mode) {
      case ConnectionMode.lanOnly:
        return lanBaseUrl ?? baseUrl;
      case ConnectionMode.publicOnly:
        return _nonEmpty(publicBaseUrl) ?? baseUrl;
      case ConnectionMode.lanFirst:
      case ConnectionMode.auto:
        if (publicIsSelected) return _nonEmpty(publicBaseUrl) ?? baseUrl;
        return lanBaseUrl ?? _nonEmpty(publicBaseUrl) ?? baseUrl;
    }
  }

  /// The WebSocket URL to connect to: the explicit override when present,
  /// otherwise derived from the effective endpoint.
  String get effectiveWsUrl {
    final override = wsUrlOverride?.trim() ?? '';
    if (override.isNotEmpty) return override;
    switch (mode) {
      case ConnectionMode.lanOnly:
        return lanWsUrl ?? deriveWebSocketUrl(effectiveBaseUrl);
      case ConnectionMode.publicOnly:
        return _nonEmpty(publicWsUrl) ?? deriveWebSocketUrl(effectiveBaseUrl);
      case ConnectionMode.lanFirst:
      case ConnectionMode.auto:
        if (publicIsSelected) {
          return _nonEmpty(publicWsUrl) ?? deriveWebSocketUrl(effectiveBaseUrl);
        }
        return lanWsUrl ??
            _nonEmpty(publicWsUrl) ??
            deriveWebSocketUrl(effectiveBaseUrl);
    }
  }

  bool get isComplete => effectiveBaseUrl.isNotEmpty && token.isNotEmpty;

  ConnectionProfile copyWith({
    String? baseUrl,
    String? token,
    String? tlsFingerprint,
    String? deviceId,
    Object? pairingCode = _unset,
    String? wsUrlOverride,
    List<EndpointRef>? lanRoutes,
    Object? selectedBaseUrl = _unset,
    String? publicBaseUrl,
    String? publicWsUrl,
    ConnectionMode? mode,
    String? configRevision,
  }) {
    return ConnectionProfile(
      baseUrl: baseUrl ?? this.baseUrl,
      token: token ?? this.token,
      tlsFingerprint: tlsFingerprint ?? this.tlsFingerprint,
      deviceId: deviceId ?? this.deviceId,
      pairingCode: identical(pairingCode, _unset)
          ? this.pairingCode
          : pairingCode as String?,
      wsUrlOverride: wsUrlOverride ?? this.wsUrlOverride,
      lanRoutes: lanRoutes ?? this.lanRoutes,
      selectedBaseUrl: identical(selectedBaseUrl, _unset)
          ? this.selectedBaseUrl
          : selectedBaseUrl as String?,
      publicBaseUrl: publicBaseUrl ?? this.publicBaseUrl,
      publicWsUrl: publicWsUrl ?? this.publicWsUrl,
      mode: mode ?? this.mode,
      configRevision: configRevision ?? this.configRevision,
    );
  }

  Map<String, dynamic> toJson() => {
    'baseUrl': baseUrl,
    'token': token,
    'tlsFingerprint': tlsFingerprint,
    'deviceId': deviceId,
    'wsUrlOverride': wsUrlOverride,
    'lanRoutes': [for (final r in lanRoutes) r.toJson()],
    'selectedBaseUrl': selectedBaseUrl,
    // Legacy single-LAN keys kept for older readers; mirror the active route.
    'lanBaseUrl': lanBaseUrl,
    'lanWsUrl': lanWsUrl,
    'publicBaseUrl': publicBaseUrl,
    'publicWsUrl': publicWsUrl,
    'mode': connectionModeToWire(mode),
    'configRevision': configRevision,
  };

  factory ConnectionProfile.fromJson(Map<String, dynamic> json) {
    final rawRoutes = json['lanRoutes'];
    final routes = rawRoutes is List
        ? rawRoutes
              .whereType<Map<String, dynamic>>()
              .map(EndpointRef.fromJson)
              .where((r) => r.baseUrl.isNotEmpty)
              .toList(growable: false)
        : const <EndpointRef>[];
    return ConnectionProfile(
      baseUrl: (json['baseUrl'] as String?) ?? '',
      token: (json['token'] as String?) ?? '',
      tlsFingerprint: (json['tlsFingerprint'] as String?) ?? '',
      deviceId: (json['deviceId'] as String?) ?? '',
      wsUrlOverride: json['wsUrlOverride'] as String?,
      lanRoutes: routes.isNotEmpty ? routes : null,
      // Fall back to the legacy single-LAN keys when no route list is stored.
      lanBaseUrl: routes.isEmpty ? json['lanBaseUrl'] as String? : null,
      lanWsUrl: routes.isEmpty ? json['lanWsUrl'] as String? : null,
      selectedBaseUrl: (json['selectedBaseUrl'] as String?),
      publicBaseUrl: json['publicBaseUrl'] as String?,
      publicWsUrl: json['publicWsUrl'] as String?,
      mode: connectionModeFromWire(json['mode'] as String?),
      configRevision: (json['configRevision'] as String?) ?? '',
    );
  }

  /// Redacted description — never prints the token.
  @override
  String toString() =>
      'ConnectionProfile(baseUrl: $baseUrl, token: <redacted>, '
      'lanRoutes: ${lanRoutes.length}, selected: $selectedBaseUrl, '
      'wsUrlOverride: $wsUrlOverride, mode: ${connectionModeToWire(mode)})';
}

const Object _unset = Object();

String? _nonEmpty(String? value) {
  final v = value?.trim() ?? '';
  return v.isEmpty ? null : v;
}
