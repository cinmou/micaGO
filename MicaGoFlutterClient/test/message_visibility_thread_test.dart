import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mica_go/core/app_controller.dart';
import 'package:mica_go/core/network/api_client.dart';
import 'package:mica_go/core/storage/secure_store.dart';
import 'package:mica_go/features/chats/thread_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class TestStore implements SecureStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestApp extends AppController {
  TestApp(this.client) : super(store: TestStore());
  final ApiClient client;
  @override
  ApiClient get api => client;
}

class RecoveryApp extends TestApp {
  RecoveryApp(super.client);
  @override
  bool get isForegroundRecovering => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('micago-visibility-');
    await databaseFactory.setDatabasesPath(directory.path);
  });
  tearDownAll(() => directory.delete(recursive: true));
  test(
    'late pre-lock history timeout stays quiet and retries after recovery',
    () async {
      final pending = Completer<http.Response>();
      final started = Completer<void>();
      var calls = 0;
      final api = ApiClient(
        baseUrl: 'http://test',
        token: 'test',
        httpClient: MockClient((request) {
          calls++;
          if (calls == 1) {
            started.complete();
            return pending.future;
          }
          return Future.value(
            http.Response(
              '{"data":[{"guid":"recovered","chatGuid":"recovery-route","text":"hello","dateCreated":100}],"hasMore":false}',
              200,
            ),
          );
        }),
      );
      final app = RecoveryApp(api);
      await app.cache.open();
      final thread = ThreadController(app: app, chatGuid: 'recovery-route');
      try {
        final loading = thread.load(showSpinner: false);
        await started.future;
        app.setForeground(false);
        app.setForeground(true);
        app.connectionHealthy.value = true;
        pending.completeError(TimeoutException('request started before lock'));
        await loading;
        expect(thread.error, isNull);
        final recovered = Completer<void>();
        thread.addListener(() {
          if (thread.messages.isNotEmpty && !recovered.isCompleted) {
            recovered.complete();
          }
        });
        await recovered.future.timeout(const Duration(seconds: 3));
        expect(thread.messages.single.guid, 'recovered');
        expect(calls, 2);
        expect(thread.error, isNull);
      } finally {
        thread.dispose();
        app.dispose();
        api.close();
        await app.cache.close();
      }
    },
  );

  test('remote hide and restore update an already open thread', () async {
    var revision = 0;
    var hidden = false;
    final client = ApiClient(
      baseUrl: 'http://test',
      token: 'test',
      httpClient: MockClient((request) async {
        if (request.url.path == '/api/message-preferences') {
          return http.Response(
            jsonEncode({
              'serverId': 'a' * 32,
              'revision': revision,
              'data': [
                if (revision > 0)
                  {
                    'messageKey': 'route-a\u001fm1',
                    'hidden': hidden,
                    'revision': revision,
                  },
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/api/messages/history') {
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'guid': 'm1',
                  'chatGuid': 'route-a',
                  'text': 'hello',
                  'dateCreated': 100,
                  'isFromMe': false,
                },
              ],
              'hasMore': false,
            }),
            200,
          );
        }
        return http.Response('{"data":[],"hasMore":false}', 200);
      }),
    );
    final app = TestApp(client);
    await app.cache.open();
    await app.messagePreferences.sync();
    final thread = ThreadController(app: app, chatGuid: 'route-a');
    thread.start();
    await thread.load();
    expect(thread.messages.map((m) => m.guid), ['m1']);
    hidden = true;
    revision = 1;
    await app.messagePreferences.sync();
    expect(thread.messages, isEmpty);
    await thread.load(showSpinner: false);
    expect(
      thread.messages,
      isEmpty,
      reason: 'REST refresh resurrected a hidden row',
    );
    hidden = false;
    revision = 2;
    await app.messagePreferences.sync();
    expect(thread.messages.map((m) => m.guid), ['m1']);
    thread.dispose();
    app.dispose();
    await app.cache.close();
  });
}
