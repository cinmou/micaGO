import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/storage/media_cache.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mica_go/core/network/api_client.dart';

void main() {
  test(
    'media arriving after rejection is withheld along with memory hits',
    () async {
      final media = MediaCache.instance;
      media.accessAllowed = true;
      addTearDown(() {
        media.accessAllowed = true;
        media.unpinLocal('revoked-test-media');
      });
      final pending = Completer<Uint8List>();
      final loading = media.load('revoked-test-media', () => pending.future);
      media.pinLocal('revoked-test-media', Uint8List.fromList([1, 2]));
      media.accessAllowed = false;
      expect(media.memoryHit('revoked-test-media'), isNull);
      final expectation = expectLater(
        loading,
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'unauthorized'),
        ),
      );
      pending.complete(Uint8List.fromList([3, 4]));
      await expectation;
    },
  );

  test(
    'authenticated 401 has one rejection callback and never becomes a timeout',
    () async {
      var rejected = 0;
      final api = ApiClient(
        baseUrl: 'https://relay.example',
        token: 'test-credential',
        onUnauthorized: () => rejected++,
        httpClient: MockClient(
          (request) async => http.Response('not authorized', 401),
        ),
      );
      addTearDown(api.close);
      await expectLater(
        api.authCheck(),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'unauthorized'),
        ),
      );
      expect(rejected, 1);
      await expectLater(
        api.getChats(),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 401)),
      );
      expect(rejected, 2);
    },
  );
  test(
    'unauthenticated health failure cannot revoke a saved credential',
    () async {
      var rejected = 0;
      final api = ApiClient(
        baseUrl: 'https://relay.example',
        token: 'test-credential',
        onUnauthorized: () => rejected++,
        httpClient: MockClient((request) async => http.Response('', 401)),
      );
      addTearDown(api.close);
      await expectLater(api.health(), throwsA(isA<ApiException>()));
      expect(rejected, 0);
    },
  );
}
