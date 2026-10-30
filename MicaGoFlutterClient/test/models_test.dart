import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/models/connection_profile.dart';
import 'package:mica_go/core/models/server_urls.dart';
import 'package:mica_go/core/network/connection_candidate.dart';

void main() {
  group('ConnectionProfile', () {
    test('effectiveWsUrl derives from baseUrl when no override', () {
      final p = ConnectionProfile(
        baseUrl: 'https://mica.example.com',
        token: 'secret',
      );
      expect(p.effectiveWsUrl, 'wss://mica.example.com/ws');
    });

    test('effectiveWsUrl honors override', () {
      final p = ConnectionProfile(
        baseUrl: 'https://mica.example.com',
        token: 'secret',
        wsUrlOverride: 'wss://ws.example.com/ws',
      );
      expect(p.effectiveWsUrl, 'wss://ws.example.com/ws');
    });

    test('json round-trip', () {
      final p = ConnectionProfile(
        baseUrl: 'http://127.0.0.1:3000',
        token: 'tok',
        wsUrlOverride: null,
      );
      final back = ConnectionProfile.fromJson(p.toJson());
      expect(back.baseUrl, p.baseUrl);
      expect(back.token, p.token);
      expect(back.wsUrlOverride, isNull);
    });

    test('candidate list and token survive json round-trip', () {
      final p = ConnectionProfile(
        baseUrl: 'http://192.168.1.5:3000',
        token: 'tok',
        lanBaseUrl: 'http://192.168.1.5:3000',
        lanWsUrl: 'ws://192.168.1.5:3000/ws',
        publicBaseUrl: 'https://micago.example.com',
        publicWsUrl: 'wss://micago.example.com/ws',
        mode: ConnectionMode.lanFirst,
      );

      final back = ConnectionProfile.fromJson(p.toJson());
      final candidates = connectionCandidatesForProfile(back);

      expect(back.token, 'tok');
      expect(candidates.map((e) => e.kind), [
        ConnectionCandidateKind.lan,
        ConnectionCandidateKind.public,
      ]);
      expect(candidates.map((e) => e.wsUrl), [
        'ws://192.168.1.5:3000/ws',
        'wss://micago.example.com/ws',
      ]);
    });

    test(
      'multiple LAN routes survive round-trip and all become candidates',
      () {
        final p = ConnectionProfile(
          baseUrl: 'http://192.168.1.5:3000',
          token: 'tok',
          lanRoutes: const [
            EndpointRef(
              baseUrl: 'http://192.168.1.5:3000',
              wsUrl: 'ws://192.168.1.5:3000/ws',
            ),
            EndpointRef(
              baseUrl: 'http://10.0.0.9:3000',
              wsUrl: 'ws://10.0.0.9:3000/ws',
            ),
          ],
          mode: ConnectionMode.lanFirst,
        );
        final back = ConnectionProfile.fromJson(p.toJson());
        final candidates = connectionCandidatesForProfile(back);
        expect(candidates.length, 2);
        expect(candidates.map((e) => e.baseUrl), [
          'http://192.168.1.5:3000',
          'http://10.0.0.9:3000',
        ]);
      },
    );

    test('a pinned route is tried first; clearing it restores order', () {
      final base = ConnectionProfile(
        baseUrl: 'http://192.168.1.5:3000',
        token: 'tok',
        lanRoutes: const [
          EndpointRef(
            baseUrl: 'http://192.168.1.5:3000',
            wsUrl: 'ws://192.168.1.5:3000/ws',
          ),
          EndpointRef(
            baseUrl: 'http://10.0.0.9:3000',
            wsUrl: 'ws://10.0.0.9:3000/ws',
          ),
        ],
      );
      final pinned = base.copyWith(selectedBaseUrl: 'http://10.0.0.9:3000');
      expect(
        connectionCandidatesForProfile(pinned).first.baseUrl,
        'http://10.0.0.9:3000',
      );
      expect(pinned.lanBaseUrl, 'http://10.0.0.9:3000');

      final cleared = pinned.copyWith(selectedBaseUrl: null);
      expect(
        connectionCandidatesForProfile(cleared).first.baseUrl,
        'http://192.168.1.5:3000',
      );
    });

    test('a stale pin falls back to the first real route', () {
      final p = ConnectionProfile(
        baseUrl: 'http://192.168.1.5:3000',
        token: 'tok',
        lanRoutes: const [
          EndpointRef(
            baseUrl: 'http://192.168.1.5:3000',
            wsUrl: 'ws://192.168.1.5:3000/ws',
          ),
        ],
        selectedBaseUrl: 'http://10.0.0.9:3000',
      );
      expect(p.lanBaseUrl, 'http://192.168.1.5:3000');
    });

    test('toString never leaks the token', () {
      final p = ConnectionProfile(baseUrl: 'http://x', token: 'topsecret');
      expect(p.toString().contains('topsecret'), isFalse);
      expect(p.toString().contains('redacted'), isTrue);
    });
  });

  group('ServerUrls.fromJson', () {
    test('parses lan/public (C25: no loopback/local)', () {
      final urls = ServerUrls.fromJson({
        'lan': [
          {
            'kind': 'lan',
            'label': 'LAN',
            'baseUrl': 'http://192.168.1.23:3000',
            'wsUrl': 'ws://192.168.1.23:3000/ws',
            'reachable': 'unknown',
          },
        ],
        'public': {
          'enabled': true,
          'kind': 'custom',
          'baseUrl': 'https://mica.example.com',
          'wsUrl': 'wss://mica.example.com/ws',
          'reachable': 'unknown',
          'verifyTls': true,
          'lastCheckedAt': 1717372805000,
        },
        'preferredPairingEndpoint': 'auto',
      });

      expect(urls.lan, hasLength(1));
      expect(urls.lan.first.baseUrl, 'http://192.168.1.23:3000');
      expect(urls.public?.enabled, isTrue);
    });

    test('handles missing public block', () {
      final urls = ServerUrls.fromJson({'lan': []});
      expect(urls.public, isNull);
    });
  });
}
