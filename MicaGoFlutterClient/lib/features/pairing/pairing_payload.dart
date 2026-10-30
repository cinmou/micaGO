import 'dart:convert';

import '../../core/models/connection_profile.dart'
    show ConnectionProfile, ConnectionMode, EndpointRef;
import '../../core/network/endpoint_utils.dart';
import '../../core/l10n/app_localizations.dart';

/// Thrown when a scanned QR code is not a valid MicaGo pairing payload.
class PairingParseException implements Exception {
  final String message;
  const PairingParseException(this.message);
  @override
  String toString() => 'PairingParseException: $message';
}

/// Local and unknown endpoint kinds are excluded from pairing candidates.
enum EndpointKind { lan, public, local }

EndpointKind endpointKindFromWire(String? v) {
  switch (v) {
    case 'lan':
      return EndpointKind.lan;
    case 'public':
      return EndpointKind.public;
    default:
      return EndpointKind.local;
  }
}

/// One advertised pairing endpoint.
class PairingEndpoint {
  final EndpointKind kind;
  final String baseUrl;
  final String? wsUrl;
  final int priority; // lower = tried first
  final bool hidden;

  const PairingEndpoint({
    required this.kind,
    required this.baseUrl,
    this.wsUrl,
    this.priority = 1,
    this.hidden = false,
  });

  String get effectiveWsUrl => (wsUrl?.trim().isNotEmpty ?? false)
      ? wsUrl!.trim()
      : deriveWebSocketUrl(baseUrl);
}

/// A secure v4 invitation, redeemed for device credentials on activation.
class PairingPayload {
  final int version;
  final ConnectionMode mode;
  final String token;
  final String tlsFingerprint;
  final String? serverName;
  final List<PairingEndpoint> endpoints;

  /// Detects advertised route changes after pairing.
  final String configRevision;

  const PairingPayload({
    required this.version,
    required this.mode,
    required this.token,
    this.tlsFingerprint = '',
    required this.endpoints,
    this.serverName,
    this.configRevision = '',
  });

  PairingEndpoint? get _primary => endpoints.isEmpty ? null : endpoints.first;

  PairingEndpoint? get lan =>
      endpoints.where((e) => e.kind == EndpointKind.lan).firstOrNull;
  Iterable<PairingEndpoint> get lanAll =>
      endpoints.where((e) => e.kind == EndpointKind.lan);
  PairingEndpoint? get public =>
      endpoints.where((e) => e.kind == EndpointKind.public).firstOrNull;

  /// Primary base URL, preferring a LAN route.
  String get baseUrl => (lan ?? _primary)?.baseUrl ?? '';
  String? get websocketUrl => (lan ?? _primary)?.wsUrl;
  String get effectiveWsUrl =>
      (lan ?? _primary)?.effectiveWsUrl ?? deriveWebSocketUrl(baseUrl);

  /// Builds the saved connection profile, populating LAN/Public URLs + mode so
  /// the runtime endpoint selector can fall back correctly.
  ConnectionProfile toProfile() {
    final lanE = lan;
    final publicE = public;
    final primary = lanE ?? _primary;
    // Retain every LAN interface for runtime route selection.
    final lanRoutes = [
      for (final e in lanAll)
        EndpointRef(
          baseUrl: normalizeBaseUrl(e.baseUrl),
          wsUrl: e.effectiveWsUrl,
        ),
    ];
    return ConnectionProfile(
      baseUrl: normalizeBaseUrl(primary?.baseUrl ?? ''),
      token: token,
      tlsFingerprint: tlsFingerprint,
      pairingCode: token,
      wsUrlOverride: (primary?.wsUrl?.trim().isNotEmpty ?? false)
          ? primary!.wsUrl!.trim()
          : null,
      lanRoutes: lanRoutes.isNotEmpty ? lanRoutes : null,
      publicBaseUrl: publicE == null ? null : normalizeBaseUrl(publicE.baseUrl),
      publicWsUrl: publicE?.wsUrl,
      mode: mode,
      configRevision: configRevision,
    );
  }

  @override
  String toString() =>
      'PairingPayload(v$version, mode: $mode, endpoints: ${endpoints.length}, token: <redacted>)';
}

/// Parses a v4 invitation or throws [PairingParseException].
PairingPayload parsePairingPayload(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    throw PairingParseException(MicaLocalizations.current.t('pair.qrEmpty'));
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } catch (_) {
    throw const PairingParseException(
      "This QR code isn't a MicaGo pairing code.",
    );
  }
  if (decoded is! Map<String, dynamic>) {
    throw const PairingParseException(
      "This QR code isn't a MicaGo pairing code.",
    );
  }

  if (decoded['version'] != 4) {
    throw PairingParseException(
      MicaLocalizations.current.t('pair.secureUpgrade'),
    );
  }
  final token = (decoded['pairingCode'] as String?)?.trim() ?? '';
  if (token.isEmpty) {
    throw PairingParseException(
      MicaLocalizations.current.t('pair.missingToken'),
    );
  }

  if (decoded['candidates'] is! List) {
    throw PairingParseException(
      MicaLocalizations.current.t('pair.noUsableEndpoint'),
    );
  }
  return _parseCandidates(decoded, token);
}

PairingPayload _parseCandidates(Map<String, dynamic> decoded, String token) {
  final rawCandidates = (decoded['candidates'] as List)
      .whereType<Map<String, dynamic>>()
      .toList(growable: false);

  final parsed = <PairingEndpoint>[];
  for (final e in rawCandidates) {
    final baseUrl = (e['baseUrl'] as String?)?.trim() ?? '';
    if (baseUrl.isEmpty || !isValidHttpUrl(baseUrl)) continue;
    final ws = (e['wsUrl'] as String?)?.trim();
    _validateWs(ws);
    parsed.add(
      PairingEndpoint(
        kind: endpointKindFromWire(e['kind'] as String?),
        baseUrl: baseUrl,
        wsUrl: (ws?.isNotEmpty ?? false) ? ws : null,
        priority: (e['priority'] as num?)?.toInt() ?? 1,
        hidden:
            _boolFlag(e['hidden']) ||
            _boolFlag(e['isHidden']) ||
            _boolFlag(e['disabled']) ||
            (e.containsKey('enabled') && !_boolFlag(e['enabled'])),
      ),
    );
  }

  // Hidden and local routes are not pairing candidates.
  final usable =
      parsed.where((e) => e.kind != EndpointKind.local && !e.hidden).toList()
        ..sort((a, b) => a.priority.compareTo(b.priority));
  if (usable.isEmpty) {
    throw PairingParseException(
      MicaLocalizations.current.t('pair.noUsableEndpoint'),
    );
  }

  if (!RegExp(
        r'^[a-fA-F0-9]{64}$',
      ).hasMatch((decoded['tlsFingerprint'] as String?) ?? '') ||
      usable.any((e) => !isSecureEndpointPair(e.baseUrl, e.effectiveWsUrl))) {
    throw const PairingParseException(
      'Invalid secure pairing endpoints or certificate fingerprint.',
    );
  }
  return PairingPayload(
    version: 4,
    tlsFingerprint: (decoded['tlsFingerprint'] as String?) ?? '',

    mode: ConnectionMode.lanFirst,
    token: token,
    serverName: (decoded['serverName'] as String?)?.trim(),
    configRevision: (decoded['configRevision'] as String?)?.trim() ?? '',
    endpoints: usable,
  );
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

void _validateWs(String? wsRaw) {
  if (wsRaw == null || wsRaw.isEmpty) return;
  final ws = Uri.tryParse(wsRaw);
  if (ws == null || (ws.scheme != 'ws' && ws.scheme != 'wss')) {
    throw PairingParseException(MicaLocalizations.current.t('pair.wsScheme'));
  }
}
