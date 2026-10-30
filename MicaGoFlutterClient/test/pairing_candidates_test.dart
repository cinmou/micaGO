import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/models/connection_profile.dart';
import 'package:mica_go/core/network/connection_candidate.dart';
import 'package:mica_go/features/pairing/pairing_payload.dart';

const _lanCandidate = {
  'kind': 'lan',
  'baseUrl': 'https://192.168.1.23:3000',
  'wsUrl': 'wss://192.168.1.23:3000/ws',
  'priority': 1,
};
const _publicCandidate = {
  'kind': 'public',
  'baseUrl': 'https://micago.example.com',
  'wsUrl': 'wss://micago.example.com/ws',
  'priority': 2,
};

String _v4({required bool withPublic}) => jsonEncode({
  'version': 4,
  'pairingCode': 'secret-token',
  'tlsFingerprint': 'a' * 64,
  'serverName': 'Mac mini',
  'configRevision': 'abc123def456',
  'candidates': [_lanCandidate, if (withPublic) _publicCandidate],
});

String _v4Custom(List<Map<String, Object?>> candidates) => jsonEncode({
  'version': 4,
  'pairingCode': 'secret-token',
  'tlsFingerprint': 'a' * 64,
  'serverName': 'Mac mini',
  'configRevision': 'abc123def456',
  'candidates': candidates,
});

void main() {
  group('secure v4 connection candidates', () {
    test('parses LAN + Public candidates, no manual mode', () {
      final p = parsePairingPayload(_v4(withPublic: true));
      expect(p.version, 4);
      expect(p.token, 'secret-token');
      expect(p.lan, isNotNull);
      expect(p.public, isNotNull);
      expect(p.configRevision, 'abc123def456');
      // Route selection remains LAN-first.
      expect(p.mode, ConnectionMode.lanFirst);
    });

    test('works with LAN only (no public)', () {
      final p = parsePairingPayload(_v4(withPublic: false));
      expect(p.lan, isNotNull);
      expect(p.public, isNull);
    });

    test('a pasted connection JSON imports exactly like a scan', () {
      // The paste path feeds the same string into parsePairingPayload.
      final pasted = '  ${_v4(withPublic: true)}  ';
      final p = parsePairingPayload(pasted.trim());
      expect(p.version, 4);
      expect(p.lan!.baseUrl, 'https://192.168.1.23:3000');
    });

    test('toProfile stores all candidates + the config revision', () {
      final p = parsePairingPayload(_v4(withPublic: true));
      final profile = p.toProfile();
      expect(profile.lanBaseUrl, 'https://192.168.1.23:3000');
      expect(profile.publicBaseUrl, 'https://micago.example.com');
      expect(profile.configRevision, 'abc123def456');
      // Profile round-trips the revision through JSON.
      expect(
        ConnectionProfile.fromJson(profile.toJson()).configRevision,
        'abc123def456',
      );
    });

    test('auto-selects LAN first, then Public as the fallback', () {
      final profile = parsePairingPayload(_v4(withPublic: true)).toProfile();
      final candidates = connectionCandidatesForProfile(profile);
      expect(candidates.map((c) => c.kind).toList(), [
        ConnectionCandidateKind.lan,
        ConnectionCandidateKind.public,
      ]);
    });

    // C23r: Public is optional and never required to pair.
    test('LAN-only profile yields a single LAN candidate (no fallback)', () {
      final profile = parsePairingPayload(_v4(withPublic: false)).toProfile();
      final candidates = connectionCandidatesForProfile(profile);
      expect(candidates.map((c) => c.kind).toList(), [
        ConnectionCandidateKind.lan,
      ]);
      expect(profile.publicBaseUrl, isNull);
    });

    test('Public-only payload is valid and selects Public', () {
      final p = parsePairingPayload(_v4Custom([_publicCandidate]));
      expect(p.version, 4);
      expect(p.lan, isNull);
      expect(p.public, isNotNull);
      final candidates = connectionCandidatesForProfile(p.toProfile());
      expect(candidates.map((c) => c.kind).toList(), [
        ConnectionCandidateKind.public,
      ]);
    });
  });
}
