import '../models/connection_profile.dart';
import 'endpoint_utils.dart';

enum ConnectionCandidateKind { lan, public }

class ConnectionCandidate {
  final ConnectionCandidateKind kind;
  final String baseUrl;
  final String wsUrl;

  const ConnectionCandidate({
    required this.kind,
    required this.baseUrl,
    required this.wsUrl,
  });

  String get label => kind == ConnectionCandidateKind.lan ? 'LAN' : 'Public';

  @override
  String toString() => '$label(base=$baseUrl, ws=$wsUrl)';
}

List<ConnectionCandidate> connectionCandidatesForProfile(
  ConnectionProfile profile,
) {
  // All advertised LAN routes (C26 multi-LAN), not just the first interface.
  final lanCandidates = <ConnectionCandidate>[
    for (final r in profile.lanRoutes)
      if (r.baseUrl.trim().isNotEmpty)
        ConnectionCandidate(
          kind: ConnectionCandidateKind.lan,
          baseUrl: normalizeBaseUrl(r.baseUrl),
          wsUrl: _nonEmpty(r.wsUrl) ?? deriveWebSocketUrl(r.baseUrl),
        ),
  ];

  ConnectionCandidate? pub;
  final publicBase = _nonEmpty(profile.publicBaseUrl);
  if (publicBase != null) {
    pub = ConnectionCandidate(
      kind: ConnectionCandidateKind.public,
      baseUrl: normalizeBaseUrl(publicBase),
      wsUrl: _nonEmpty(profile.publicWsUrl) ?? deriveWebSocketUrl(publicBase),
    );
  }

  final fallback = ConnectionCandidate(
    kind: profile.mode == ConnectionMode.publicOnly
        ? ConnectionCandidateKind.public
        : ConnectionCandidateKind.lan,
    baseUrl: normalizeBaseUrl(profile.baseUrl),
    wsUrl:
        _nonEmpty(profile.wsUrlOverride) ?? deriveWebSocketUrl(profile.baseUrl),
  );

  final out = <ConnectionCandidate>[];
  switch (profile.mode) {
    case ConnectionMode.lanOnly:
      out.addAll(lanCandidates);
      break;
    case ConnectionMode.publicOnly:
      if (pub != null) out.add(pub);
      break;
    case ConnectionMode.lanFirst:
    case ConnectionMode.auto:
      out.addAll(lanCandidates);
      if (pub != null) out.add(pub);
      break;
  }
  if (out.isEmpty && fallback.baseUrl.isNotEmpty) out.add(fallback);
  // Honour a manual route pin: move the selected candidate to the front so it
  // is tried first on connect/reconnect, while keeping the others as fallbacks.
  final selected = _nonEmpty(profile.selectedBaseUrl);
  if (selected != null) {
    final normSelected = normalizeBaseUrl(selected);
    final idx = out.indexWhere((c) => c.baseUrl == normSelected);
    if (idx > 0) {
      final pick = out.removeAt(idx);
      out.insert(0, pick);
    }
  }
  return _dedupe(out);
}

/// C75: decides which LAN routes to persist after a `/api/server/urls` refresh.
///
/// An empty [reported] list means "the server listed no LAN endpoints right
/// now" — the Mac's Wi-Fi may still be coming up after wake, an interface may
/// have changed, or the query went through the public tunnel. That is NOT the
/// same as "the user removed them", so the previously stored routes are kept.
/// Only a server that actually uses visibility flags (hidden/disabled) is
/// trusted to say "there are none", because then the empty result is a real
/// decision rather than a gap in the report.
List<EndpointRef> resolvePersistedLanRoutes({
  required List<EndpointRef> reported,
  required List<EndpointRef> previous,
  required bool serverUsesVisibilityFlags,
}) {
  if (reported.isNotEmpty) return reported;
  if (serverUsesVisibilityFlags) return reported;
  return previous;
}

String? _nonEmpty(String? value) {
  final v = value?.trim() ?? '';
  return v.isEmpty ? null : v;
}

List<ConnectionCandidate> _dedupe(List<ConnectionCandidate> input) {
  final seen = <String>{};
  final out = <ConnectionCandidate>[];
  for (final c in input) {
    if (seen.add(c.baseUrl)) out.add(c);
  }
  return out;
}
