import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/models/connection_profile.dart';
import 'package:mica_go/core/network/connection_candidate.dart';
import 'package:mica_go/features/pairing/pairing_payload.dart';

String _v2({String mode = 'lanFirst', bool lan = true, bool public = true}) {
  final endpoints = <Map<String, dynamic>>[
    if (lan)
      {'kind': 'lan', 'baseUrl': 'http://192.168.1.23:3000', 'priority': 1},
    if (public)
      {
        'kind': 'public',
        'baseUrl': 'https://micago.example.com',
        'priority': 2,
      },
  ];
  return jsonEncode({
    'version': 2,
    'mode': mode,
    'token': 'tok',
    'serverName': 'Mac mini',
    'endpoints': endpoints,
  });
}

void main() {
  group('v1 back-compat', () {
    test('legacy single-baseUrl payload still parses', () {
      final p = parsePairingPayload(
        '{"baseUrl":"https://go.example.com","token":"t"}',
      );
      expect(p.version, 1);
      expect(p.baseUrl, 'https://go.example.com');
      expect(p.token, 't');
      expect(p.toProfile().baseUrl, 'https://go.example.com');
    });
  });

  group('v2 parsing', () {
    test('parses endpoints, mode, serverName', () {
      final p = parsePairingPayload(_v2());
      expect(p.version, 2);
      expect(p.mode, ConnectionMode.lanFirst);
      expect(p.serverName, 'Mac mini');
      expect(p.lan!.baseUrl, 'http://192.168.1.23:3000');
      expect(p.public!.baseUrl, 'https://micago.example.com');
    });

    test('toProfile populates lan/public + mode', () {
      final prof = parsePairingPayload(_v2()).toProfile();
      expect(prof.lanBaseUrl, 'http://192.168.1.23:3000');
      expect(prof.publicBaseUrl, 'https://micago.example.com');
      expect(prof.mode, ConnectionMode.lanFirst);
    });

    test('setup payload with LAN + Public becomes two runtime candidates', () {
      final prof = parsePairingPayload(_v2()).toProfile();
      final candidates = connectionCandidatesForProfile(prof);

      expect(candidates.map((e) => e.kind), [
        ConnectionCandidateKind.lan,
        ConnectionCandidateKind.public,
      ]);
      expect(candidates[0].baseUrl, 'http://192.168.1.23:3000');
      expect(candidates[1].baseUrl, 'https://micago.example.com');
    });

    test('public HTTPS candidate derives WSS /ws URL', () {
      final prof = parsePairingPayload(_v2()).toProfile();
      final public = connectionCandidatesForProfile(
        prof,
      ).singleWhere((e) => e.kind == ConnectionCandidateKind.public);

      expect(public.wsUrl, 'wss://micago.example.com/ws');
    });

    test('LAN-only payload drops any public endpoint', () {
      final p = parsePairingPayload(_v2(mode: 'lan_only'));
      expect(p.mode, ConnectionMode.lanOnly);
      expect(p.public, isNull);
      expect(p.endpoints.length, 1);
    });

    test('loopback/local endpoints are never surfaced', () {
      final raw = jsonEncode({
        'version': 2,
        'mode': 'lanFirst',
        'token': 't',
        'endpoints': [
          {'kind': 'local', 'baseUrl': 'http://127.0.0.1:3000', 'priority': 0},
          {'kind': 'lan', 'baseUrl': 'http://192.168.1.5:3000', 'priority': 1},
        ],
      });
      final p = parsePairingPayload(raw);
      expect(p.endpoints.every((e) => e.kind != EndpointKind.local), isTrue);
      expect(p.lan!.baseUrl, 'http://192.168.1.5:3000');
    });

    test('rejects a payload with no usable endpoint', () {
      final raw = jsonEncode({
        'version': 2,
        'token': 't',
        'endpoints': [
          {'kind': 'local', 'baseUrl': 'http://127.0.0.1:3000'},
        ],
      });
      expect(
        () => parsePairingPayload(raw),
        throwsA(isA<PairingParseException>()),
      );
    });

    test('missing token rejected', () {
      expect(
        () => parsePairingPayload('{"version":2,"endpoints":[]}'),
        throwsA(isA<PairingParseException>()),
      );
    });
  });
}
