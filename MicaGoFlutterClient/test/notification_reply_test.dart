import 'dart:convert';
import 'read_state_sync_test.dart' show ReadCache, ReadServer;
import 'package:mica_go/core/network/read_state_sync.dart';
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

class _ReadApp extends _App {
  _ReadApp(super.client);
  final ReadCache _readCache = ReadCache();
  @override
  ReadCache get cache => _readCache;
  @override
  ReadStateSync get readState => _readSync;
  late final ReadStateSync _readSync = ReadStateSync(
    cache: cache,
    api: () => api,
    onChanged: (_) async {},
  );
  @override
  Future<void> runDeltaSync({required String reason}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'mark read is route-scoped, monotonic, and refuses legacy or stale actions',
    () async {
      final server = ReadServer();
      final app = _ReadApp(server.client);
      addTearDown(() {
        app.dispose();
        server.client.close();
      });
      expect(
        await markNotificationRead(
          notificationPayload('a', 'old', readThrough: 100),
          app: app,
        ),
        'read failed',
      );
      expect(
        await markNotificationRead(
          notificationPayload('a', 'current-device'),
          app: app,
        ),
        'read failed',
      );
      expect(server.sentScopes, isEmpty);
      server.rows['b'] = 200;
      server.marks['a'] = {'markedUnread': true, 'unreadRevision': 3};
      final payload = notificationPayload(
        'a',
        'current-device',
        readThrough: 100,
      );
      expect(await markNotificationRead(payload, app: app), 'read saved');
      expect(server.rows, {'a': 100, 'b': 200});
      expect(server.marks['a']!['markedUnread'], false);
      expect(app.cache.seen['a'], 100);
      // An old action cannot regress read state or clear a newer manual mark.
      server.rows['a'] = 300;
      server.marks['a'] = {'markedUnread': true, 'unreadRevision': 5};
      expect(await markNotificationRead(payload, app: app), 'read saved');
      expect(server.rows['a'], 300);
      expect(server.marks['a']!['markedUnread'], true);
    },
  );
  test(
    'concurrent manual unread revision prevents a stale notification clearing it',
    () async {
      Map<String, dynamic> snapshot(bool raced) => {
        'serverId': 'server',
        'revision': raced ? 1 : 0,
        'data': [
          {
            'chatGuid': 'a',
            'readThrough': 0,
            'markedUnread': raced,
            'unreadRevision': raced ? 1 : 0,
          },
        ],
      };
      final api = ApiClient(
        baseUrl: 'https://relay.example',
        token: 'test-only',
        httpClient: MockClient((request) async {
          if (request.method == 'PATCH') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect((body['changes'] as List).single['baseUnreadRevision'], 0);
            expect((body['changes'] as List).single['markedUnread'], false);
          }
          return http.Response(
            jsonEncode(snapshot(request.method == 'PATCH')),
            200,
          );
        }),
      );
      final app = _ReadApp(api);
      addTearDown(() {
        app.dispose();
        api.close();
      });
      expect(
        await markNotificationRead(
          notificationPayload('a', 'current-device', readThrough: 100),
          app: app,
        ),
        'read failed',
      );
      expect(app.cache.seen, isEmpty);
    },
  );
  test(
    'offline read retains unread and authenticated 401 rejects this credential',
    () async {
      var status = 503;
      var count = 0;
      final api = ApiClient(
        baseUrl: 'https://relay.example',
        token: 'test-only',
        httpClient: MockClient((request) async {
          count++;
          return http.Response('{}', status);
        }),
      );
      final app = _ReadApp(api);
      addTearDown(() {
        app.dispose();
        api.close();
      });
      final payload = notificationPayload(
        'a',
        'current-device',
        readThrough: 100,
      );
      expect(await markNotificationRead(payload, app: app), 'read failed');
      expect(count, 1);
      expect(app.cache.seen, isEmpty);
      status = 401;
      expect(await markNotificationRead(payload, app: app), 'read rejected');
      expect(app.rejected?.deviceId, 'current-device');
      expect(count, 2);
    },
  );
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
