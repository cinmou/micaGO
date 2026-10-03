import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mica_go/core/app_controller.dart';
import 'package:mica_go/core/models/connection_profile.dart';
import 'package:mica_go/core/network/api_client.dart';
import 'package:mica_go/core/network/push_logic.dart';
import 'package:mica_go/core/network/push_service.dart';
import 'package:mica_go/core/storage/secure_store.dart';

class _Store implements SecureStore {
  @override
  Future<String?> readValue(String key) async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _App extends AppController {
  _App(this.client) : super(store: _Store());
  final ApiClient client;
  ConnectionProfile? rejected;
  @override
  ApiClient get api => client;
  @override
  ConnectionProfile get profile => ConnectionProfile(
    baseUrl: 'https://relay.example',
    token: 'test-only',
    deviceId: 'current-device',
  );
  @override
  void rejectCredential(ConnectionProfile value) {
    rejected = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'notification reply uses normal send and refuses old-device notifications',
    () async {
      final requests = <http.Request>[];
      var status = 200;
      final api = ApiClient(
        baseUrl: 'https://relay.example',
        token: 'test-only',
        httpClient: MockClient((request) async {
          if (!request.url.path.endsWith('/send')) {
            return http.Response('{"data":[],"hasMore":false}', 200);
          }
          requests.add(request);
          return http.Response(
            status == 200
                ? '{"guid":"confirmed","chatGuid":"route-a","text":"hello"}'
                : '{}',
            status,
          );
        }),
      );
      final app = _App(api);
      addTearDown(() {
        app.dispose();
        api.close();
      });
      expect(
        await sendNotificationReply(
          notificationPayload('route-a', 'old-device'),
          'private',
          app: app,
        ),
        'reply failed',
      );
      expect(requests, isEmpty);
      final payload = notificationPayload('route-a', 'current-device');
      expect(
        await sendNotificationReply(payload, '  hello  ', app: app),
        'reply sent',
      );
      expect(requests.single.url.path, '/api/chats/route-a/send');
      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      expect(body.keys, unorderedEquals(['tempGuid', 'message']));
      expect(body['message'], 'hello');
      status = 202;
      expect(
        await sendNotificationReply(payload, 'hello', app: app),
        'reply pending',
      );
      expect(
        requests.length,
        2,
        reason: 'uncertain reply must not automatically retry',
      );
      status = 401;
      expect(
        await sendNotificationReply(payload, 'hello', app: app),
        'reply rejected',
      );
      expect(app.rejected?.deviceId, 'current-device');
    },
  );
}
