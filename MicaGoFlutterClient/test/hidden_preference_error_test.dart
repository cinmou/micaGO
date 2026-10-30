import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mica_go/core/network/api_client.dart';
import 'package:mica_go/core/network/hidden_preference_sync.dart';
import 'package:mica_go/core/storage/local_cache_store.dart';

class MemoryCache extends LocalCacheStore {
  final metadata = <String, String>{};
  @override
  Future<String?> readMetadata(String key) async => metadata[key];
  @override
  Future<void> writeMetadata(String key, String value) async {
    metadata[key] = value;
  }

  @override
  Future<Set<String>> legacyHiddenChatGuids() async => {};
  @override
  Future<Set<String>> hiddenMessageGuids() async => {};
  @override
  Future<List<HiddenMessageRecord>> hiddenMessages() async => [];
  @override
  Future<void> applyChatVisibility(Set<String> hidden) async {}
  @override
  Future<void> applyMessageVisibility(Set<String> hidden) async {}
}

void main() {
  for (final kind in HiddenPreferenceKind.values) {
    group(kind.name, () {
      late ApiClient active;
      late HiddenPreferenceSync sync;
      var status = 200;
      var invalidReply = false;
      var offline = false;
      Completer<void>? replyGate;
      Completer<void>? patchStarted;
      setUp(() {
        status = 200;
        invalidReply = false;
        offline = false;
        replyGate = null;
        patchStarted = null;
        active = ApiClient(
          baseUrl: 'http://test',
          token: 'test',
          httpClient: MockClient((request) async {
            if (offline) throw http.ClientException('offline');
            if (status != 200) {
              return http.Response(
                '{"error":{"code":"forbidden","message":"Access denied"}}',
                status,
              );
            }
            if (request.method == 'PATCH') {
              patchStarted?.complete();
              await replyGate?.future;
              if (invalidReply) {
                return http.Response('{"serverId":"server","revision":1}', 200);
              }
              final changes = (jsonDecode(request.body)['changes'] as List)
                  .cast<Map<String, dynamic>>();
              return http.Response(
                jsonEncode({
                  'serverId': 'server',
                  'revision': 1,
                  'data': [
                    for (final change in changes) {...change, 'revision': 1},
                  ],
                }),
                200,
              );
            }
            return http.Response(
              '{"serverId":"server","revision":0,"data":[]}',
              200,
            );
          }),
        );
        sync = HiddenPreferenceSync(
          kind: kind,
          cache: MemoryCache(),
          api: () => active,
          onChanged: () {},
        );
        addTearDown(sync.dispose);
        final client = active;
        addTearDown(client.close);
      });
      test(
        'server errors are visible and distinct from offline state',
        () async {
          status = 403;
          await sync.sync();
          expect(sync.errorKey, 'prefs.failed');
          expect(sync.errorMessage, 'Access denied');
          offline = true;
          await sync.sync();
          expect(sync.errorKey, 'prefs.offline');
          expect(sync.errorMessage, isNull);
          offline = false;
          status = 200;
          await sync.sync();
          expect(sync.errorKey, isNull);
        },
      );
      test(
        'malformed acknowledgement retains queued visibility change',
        () async {
          await sync.sync();
          invalidReply = true;
          final key = kind == HiddenPreferenceKind.chat
              ? 'chat'
              : 'chat\u001fmessage';
          await sync.setHidden([key], true);
          expect(sync.pending, isTrue);
          expect(sync.isHidden(key), isTrue);
          expect(sync.errorKey, 'prefs.failed');
          invalidReply = false;
          await sync.sync();
          expect(sync.pending, isFalse);
          expect(sync.isHidden(key), isTrue);
        },
      );
      test(
        'an old client acknowledgement cannot consume the active queue',
        () async {
          await sync.sync();
          replyGate = Completer<void>();
          patchStarted = Completer<void>();
          final key = kind == HiddenPreferenceKind.chat
              ? 'chat'
              : 'chat\u001fmessage';
          final updating = sync.setHidden([key], true);
          await patchStarted!.future;
          active = ApiClient(
            baseUrl: 'http://other',
            token: 'other',
            httpClient: MockClient((_) async => http.Response('{}', 200)),
          );
          addTearDown(active.close);
          replyGate!.complete();
          await updating;
          expect(sync.pending, isTrue);
          expect(sync.isHidden(key), isTrue);
        },
      );
    });
  }
}
