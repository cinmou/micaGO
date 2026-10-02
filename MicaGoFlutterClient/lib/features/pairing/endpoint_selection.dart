/// Pure endpoint-selection logic for onboarding (C10 Part A/C).
///
/// Decides the order in which candidate endpoints are tried, enforcing the
/// product rules:
/// - LAN-only never uses Public.
/// - LAN + Public tries the LAN endpoint(s) first, then Public.
/// - Public-only tries only Public.
/// No I/O here — the onboarding controller runs the actual health/auth checks
/// against this order, so the policy is unit-testable.
library;

import '../../core/models/connection_profile.dart';
import 'pairing_payload.dart';

/// Returns the ordered list of endpoints to attempt for [mode]. LAN endpoints
/// (lower priority value first) precede Public; Public is excluded entirely for
/// [ConnectionMode.lanOnly].
List<PairingEndpoint> endpointTryOrder(
  ConnectionMode mode,
  List<PairingEndpoint> endpoints,
) {
  bool isLan(PairingEndpoint e) => e.kind == EndpointKind.lan;
  bool isPublic(PairingEndpoint e) => e.kind == EndpointKind.public;

  final lan = endpoints.where(isLan).toList()
    ..sort((a, b) => a.priority.compareTo(b.priority));
  final public = endpoints.where(isPublic).toList()
    ..sort((a, b) => a.priority.compareTo(b.priority));

  switch (mode) {
    case ConnectionMode.lanOnly:
      return lan; // never Public
    case ConnectionMode.publicOnly:
      return public;
    case ConnectionMode.lanFirst:
    case ConnectionMode.auto:
      return [...lan, ...public];
  }
}

/// Which connection modes a scanned payload actually offers the user. A payload
/// with only a LAN endpoint offers LAN-only; one with both offers LAN-only and
/// LAN + Public fallback.
List<ConnectionMode> offeredModes(PairingPayload payload) {
  // C23: the unified v3 payload has no manual mode — the client always tries
  // LAN first then Public, so we never ask the user to choose.
  if (payload.version >= 3) return const [];
  final hasLan = payload.lan != null;
  final hasPublic = payload.public != null;
  if (hasLan && hasPublic) {
    return const [ConnectionMode.lanOnly, ConnectionMode.lanFirst];
  }
  if (hasLan) return const [ConnectionMode.lanOnly];
  if (hasPublic) return const [ConnectionMode.publicOnly];
  return const [];
}

// C23 cleanup: connectionModeLabel was removed — the UI no longer shows a
// LAN-only vs LAN+Public mode chooser (the unified payload auto-selects).
