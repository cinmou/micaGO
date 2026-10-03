import 'dart:io';
import 'package:mica_go/core/network/endpoint_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/network/secure_transport.dart';
import 'package:mica_go/features/pairing/pairing_payload.dart';
import 'dart:convert';

void main() {
  test(
    'real TLS connection pins server certificate and refuses redirects',
    () async {
      // OpenSSL generates a disposable test identity. Production uses Go TLS.
      final directory = await Directory.systemTemp.createTemp(
        'micago-tls-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final certPath = '${directory.path}/test.crt';
      final keyPath = '${directory.path}/test.key';
      final generated = await Process.run('openssl', [
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-keyout',
        keyPath,
        '-out',
        certPath,
        '-days',
        '2',
        '-subj',
        '/CN=micago-test',
      ]);
      expect(
        generated.exitCode,
        0,
        reason: 'Could not create disposable TLS test identity',
      );
      final context = SecurityContext()
        ..useCertificateChain(certPath)
        ..usePrivateKey(keyPath);
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      addTearDown(() => server.close(force: true));
      String? seenToken;
      server.listen((request) async {
        seenToken = request.headers.value('authorization');
        if (request.uri.path == '/redirect') {
          request.response.statusCode = 302;
          request.response.headers.set('location', 'http://127.0.0.1:1/steal');
        } else {
          request.response.write('ok');
        }
        await request.response.close();
      });
      final pem = File(certPath).readAsStringSync();
      final der = base64Decode(
        pem
            .split('\n')
            .where((s) => !s.startsWith('-----') && s.isNotEmpty)
            .join(),
      );
      final pin = sha256.convert(der).toString();
      final base = 'https://127.0.0.1:${server.port}';
      final client = secureHttpClient(base, fingerprint: pin);
      addTearDown(client.close);
      final response = await client.get(
        Uri.parse('$base/check'),
        headers: {'Authorization': 'Bearer test-only'},
      );
      expect(response.body, 'ok');
      expect(seenToken, 'Bearer test-only');
      final redirected = await client.get(Uri.parse('$base/redirect'));
      expect(redirected.statusCode, 302);
      final wrong = secureHttpClient(
        base,
        fingerprint: List.filled(64, '0').join(),
      );
      addTearDown(wrong.close);
      await expectLater(wrong.get(Uri.parse('$base/check')), throwsA(anything));
      expect(
        () => secureHttpClient('http://127.0.0.1:${server.port}'),
        throwsStateError,
      );
      await expectLater(
        client.get(Uri.parse('https://another.example/check')),
        throwsStateError,
      );
    },
  );

  test('v4 accepts default WSS ports and rejects different secure origins', () {
    for (final ws in ['wss://relay.example/ws', 'wss://relay.example:443/ws']) {
      final input = {
        'version': 4,
        'pairingCode': List.filled(64, 'b').join(),
        'tlsFingerprint': List.filled(64, 'a').join(),
        'candidates': [
          {
            'kind': 'lan',
            'baseUrl': 'https://192.168.1.3:3001',
            'wsUrl': 'wss://192.168.1.3:3001/ws',
          },
          {'kind': 'public', 'baseUrl': 'https://relay.example', 'wsUrl': ws},
        ],
      };
      expect(parsePairingPayload(jsonEncode(input)).endpoints, hasLength(2));
      expect(transportPort(Uri.parse(ws)), 443);
      expect(isSecureEndpointPair('https://relay.example', ws), isTrue);
      for (final invalid in [
        'wss://relay.example:444/ws',
        'wss://other.example/ws',
        'ws://relay.example/ws',
      ]) {
        (input['candidates'] as List).last['wsUrl'] = invalid;
        expect(isSecureEndpointPair('https://relay.example', invalid), isFalse);
        expect(
          () => parsePairingPayload(jsonEncode(input)),
          throwsA(isA<PairingParseException>()),
        );
      }
    }
  });

  test('v4 invitation preserves server pin through profile persistence', () {
    final pin = List.filled(64, 'a').join();
    final input = {
      'version': 4,
      'pairingCode': List.filled(64, 'b').join(),
      'tlsFingerprint': pin,
      'candidates': [
        {
          'kind': 'lan',
          'baseUrl': 'https://192.168.1.3:3001',
          'wsUrl': 'wss://192.168.1.3:3001/ws',
        },
      ],
    };
    final payload = parsePairingPayload(jsonEncode(input));
    final profile = payload.toProfile();
    expect(profile.pairingCode, isNotNull);
    expect(profile.pinFor(profile.baseUrl), pin);
    final paired = profile.copyWith(
      token: 'device-token',
      deviceId: 'device-bound',
      pairingCode: null,
    );
    expect(paired.copyWith(selectedBaseUrl: null).deviceId, 'device-bound');
    expect(paired.toJson().containsKey('pairingCode'), isFalse);
    // Hiding every interface must not weaken the saved origin's TLS trust.
    expect(paired.copyWith(lanRoutes: []).pinFor(paired.baseUrl), pin);
    final public = paired.copyWith(
      baseUrl: 'https://relay.example',
      publicBaseUrl: 'https://relay.example',
      lanRoutes: [],
    );
    expect(public.pinFor(public.baseUrl), isNull);
    input['candidates'] = [
      {
        'kind': 'lan',
        'baseUrl': 'http://192.168.1.3:3000',
        'wsUrl': 'ws://192.168.1.3:3000/ws',
      },
    ];
    expect(
      () => parsePairingPayload(jsonEncode(input)),
      throwsA(isA<PairingParseException>()),
    );
  });
}
