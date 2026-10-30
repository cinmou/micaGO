import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/features/pairing/pairing_payload.dart';

Map<String, dynamic> invitation() => {
  'version': 4,
  'pairingCode': 'secret-code',
  'tlsFingerprint': 'a' * 64,
  'candidates': [
    {'kind': 'lan', 'baseUrl': 'https://go.example.com/'},
  ],
};
void main() {
  test(
    'derives secure websocket and carries redemption code and fingerprint',
    () {
      final p = parsePairingPayload(jsonEncode(invitation()));
      expect(p.effectiveWsUrl, 'wss://go.example.com/ws');
      final profile = p.toProfile();
      expect(profile.baseUrl, 'https://go.example.com');
      expect(profile.pairingCode, 'secret-code');
      expect(profile.tlsFingerprint, 'a' * 64);
      expect(p.toString(), isNot(contains('secret-code')));
    },
  );
  for (final version in [null, 1, 2, 3, 5]) {
    test('rejects unsupported invitation version $version', () {
      final input = invitation()..['version'] = version;
      expect(
        () => parsePairingPayload(jsonEncode(input)),
        throwsA(isA<PairingParseException>()),
      );
    });
  }
  for (final field in ['pairingCode', 'tlsFingerprint', 'candidates']) {
    test('rejects missing $field', () {
      final input = invitation()..remove(field);
      expect(
        () => parsePairingPayload(jsonEncode(input)),
        throwsA(isA<PairingParseException>()),
      );
    });
  }
  for (final raw in ['', 'not json', '[]']) {
    test('rejects malformed input $raw', () {
      expect(
        () => parsePairingPayload(raw),
        throwsA(isA<PairingParseException>()),
      );
    });
  }
}
