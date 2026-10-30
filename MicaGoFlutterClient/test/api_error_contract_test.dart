import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mica_go/core/network/api_client.dart';

void main() {
  final calls = <String, Future<Object?> Function(ApiClient)>{
    'sync settings': (api) => api.getSyncSettings(),
    'write settings': (api) => api.putSyncSettings({'allowSmsSend': true}),
    'mute rules': (api) => api.getMutedChatGuids(),
    'write mute': (api) async =>
        api.putSyncRule(targetKind: 'chat', targetValue: 'chat'),
    'test contact': (api) => api.getTestContactConfig(),
    'write test contact': (api) => api.setTestContact(enabled: true),
    'FCM config': (api) => api.fetchFcmClientConfig(),
    'heartbeat': (api) async => api.deviceHeartbeat('device'),
    'redeem': (api) => api.redeemPairingCode('invitation'),
  };
  for (final entry in calls.entries) {
    test('${entry.key} preserves HTTP errors', () async {
      final api = ApiClient(
        baseUrl: 'https://test',
        token: 'device',
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'error': {'code': 'forbidden', 'message': 'Denied'},
            }),
            403,
          ),
        ),
      );
      addTearDown(api.close);
      await expectLater(
        entry.value(api),
        throwsA(
          isA<ApiException>()
              .having((error) => error.statusCode, 'status', 403)
              .having((error) => error.code, 'code', 'forbidden'),
        ),
      );
    });
  }
  test(
    'proxy 401 preserves pairing; only structured micaGO rejection signals revocation',
    () async {
      var revoked = 0;
      var body = '<html>proxy login</html>';
      final api = ApiClient(
        baseUrl: 'https://test',
        token: 'device',
        onUnauthorized: () => revoked++,
        httpClient: MockClient((_) async => http.Response(body, 401)),
      );
      addTearDown(api.close);
      await expectLater(
        api.getSyncSettings(),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'http_401')),
      );
      expect(revoked, 0);
      body = '{"error":{"code":"unauthorized","message":"Revoked"}}';
      await expectLater(
        api.getSyncSettings(),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'unauthorized'),
        ),
      );
      expect(revoked, 1);
    },
  );
  test('invalid JSON and malformed optional envelopes fail visibly', () async {
    var body = 'invalid';
    final api = ApiClient(
      baseUrl: 'https://test',
      token: 'device',
      httpClient: MockClient((_) async => http.Response(body, 200)),
    );
    addTearDown(api.close);
    final badResponse = throwsA(
      isA<ApiException>().having((e) => e.code, 'code', 'bad_response'),
    );
    await expectLater(api.getSyncSettings(), badResponse);
    body = '{}';
    await expectLater(api.putSyncSettings({}), badResponse);
    await expectLater(api.getMutedChatGuids(), badResponse);
    await expectLater(api.fetchFcmClientConfig(), badResponse);
    body = '{"data":{"configured":false}}';
    expect(await api.fetchFcmClientConfig(), {'configured': false});
  });
  test('transport timeout and client exception keep distinct codes', () async {
    var timeout = true;
    final api = ApiClient(
      baseUrl: 'https://test',
      token: 'device',
      httpClient: MockClient((_) async {
        if (timeout) throw TimeoutException('timeout');
        throw http.ClientException('offline');
      }),
    );
    addTearDown(api.close);
    await expectLater(
      api.getSyncSettings(),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'timeout')),
    );
    timeout = false;
    await expectLater(
      api.getSyncSettings(),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'network_error'),
      ),
    );
  });
}
