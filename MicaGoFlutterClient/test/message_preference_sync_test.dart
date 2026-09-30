import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mica_go/core/network/api_client.dart';
import 'package:mica_go/core/network/message_preference_sync.dart';
import 'package:mica_go/core/storage/local_cache_store.dart';

class MemoryCache extends LocalCacheStore {
  final data = <String, String>{};
  Set<String> legacy = {};
  Set<String> visible = {};
  @override
  Future<String?> readMetadata(String key) async => data[key];
  @override
  Future<void> writeMetadata(String key, String value) async {
    data[key] = value;
  }

  @override
  Future<List<HiddenMessageRecord>> hiddenMessages() async => [];

  @override
  Future<Set<String>> hiddenMessageGuids() async => legacy;
  @override
  Future<void> applyMessageVisibility(Set<String> hidden) async {
    visible = hidden;
  }
}

class PreferenceServer {
  String id = 'a' * 32;
  int revision = 0;
  bool offline = false;
  bool loseReply = false;
  final rows = <String, Map<String, dynamic>>{};
  final replies = <String, String>{};
  int patches = 0;
  Map<String, dynamic> get snapshot => {
    'serverId': id,
    'revision': revision,
    'data': rows.values.toList(),
  };
  late final client = ApiClient(
    baseUrl: 'http://test',
    token: 'test',
    httpClient: MockClient((request) async {
      if (offline) throw http.ClientException('offline');
      expect(request.url.path, '/api/message-preferences');
      if (request.method == 'GET') {
        return http.Response(jsonEncode(snapshot), 200);
      }
      patches++;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final mutation = body['mutationId'] as String;
      if (replies.containsKey(mutation)) {
        return http.Response(replies[mutation]!, 200);
      }
      final changes = (body['changes'] as List).cast<Map<String, dynamic>>();
      if (body['serverId'] != id ||
          changes.any(
            (change) =>
                change['baseRevision'] !=
                (rows[change['messageKey']]?['revision'] ?? 0),
          )) {
        return http.Response('{"code":"preference_conflict"}', 409);
      }
      revision++;
      final updated = [
        for (final change in changes)
          {
            'messageKey': change['messageKey'],
            'hidden': change['hidden'],
            'revision': revision,
          },
      ];
      for (final row in updated) {
        rows[row['messageKey'] as String] = row;
      }
      final reply = jsonEncode({
        'serverId': id,
        'revision': revision,
        'data': updated,
      });
      replies[mutation] = reply;
      if (loseReply) {
        loseReply = false;
        throw http.ClientException('lost reply');
      }
      return http.Response(reply, 200);
    }),
  );
  MessagePreferenceSync device([MemoryCache? cache]) => MessagePreferenceSync(
    cache: cache ?? MemoryCache(),
    api: () => client,
    onChanged: () {},
  );
}

void main() {
  test('two devices hide and restore every selected route', () async {
    final server = PreferenceServer();
    final a = server.device();
    final b = server.device();
    await a.sync();
    await b.sync();
    await a.setHidden(['route-a\u001fmessage', 'route-b\u001fmessage'], true);
    await b.sync();
    expect(b.hidden, {'route-a\u001fmessage', 'route-b\u001fmessage'});
    await b.setHidden(['route-a\u001fmessage', 'route-b\u001fmessage'], false);
    await a.sync();
    expect(a.hidden, isEmpty);
    expect(server.revision, 2);
  });

  test(
    'offline changes survive restart and preserve same-device order',
    () async {
      final server = PreferenceServer();
      final cache = MemoryCache();
      final a = server.device(cache);
      await a.sync();
      server.offline = true;
      await a.setHidden(['route\u001fmessage'], true);
      await a.setHidden(['route\u001fmessage'], false);
      expect(a.pending, isTrue);
      expect(cache.visible, isEmpty);
      a.dispose();
      server.offline = false;
      final restarted = server.device(cache);
      await restarted.sync();
      expect(restarted.pending, isFalse);
      expect(restarted.hasConflicts, isFalse);
      expect(server.rows['route\u001fmessage']!['hidden'], false);
    },
  );

  test(
    'lost acknowledgement replays without overwriting a later device edit',
    () async {
      final server = PreferenceServer();
      final a = server.device();
      final b = server.device();
      await a.sync();
      server.loseReply = true;
      await a.setHidden(['route\u001fmessage'], true);
      expect(a.pending, isTrue);
      await b.sync();
      await b.setHidden(['route\u001fmessage'], false);
      await a.sync();
      expect(a.pending, isFalse);
      expect(a.hidden, isEmpty);
      expect(server.revision, 2);
    },
  );

  test('stale mutation conflicts until explicitly reapplied', () async {
    final server = PreferenceServer();
    final a = server.device();
    final b = server.device();
    await a.sync();
    await b.sync();
    server.offline = true;
    await a.setHidden(['route\u001fmessage'], true);
    server.offline = false;
    await b.setHidden(['route\u001fmessage'], false);
    await a.sync();
    expect(a.hasConflicts, isTrue);
    expect(a.hidden, isEmpty);
    await a.retryConflicts();
    await b.sync();
    expect(a.hasConflicts, isFalse);
    expect(b.hidden, {'route\u001fmessage'});
  });

  test('legacy records remain local until explicitly imported', () async {
    final server = PreferenceServer();
    final cache = MemoryCache()..legacy = {'old-route\u001fmessage'};
    final a = server.device(cache);
    await a.sync();
    expect(a.hidden, {'old-route\u001fmessage'});
    expect(server.patches, 0);
    await a.importLegacy();
    expect(a.legacyCount, 0);
    expect(server.rows['old-route\u001fmessage']!['hidden'], true);
  });

  test('server switch does not transmit another server outbox', () async {
    final server = PreferenceServer();
    final a = server.device();
    await a.sync();
    server.offline = true;
    await a.setHidden(['private-route\u001fmessage'], true);
    server.offline = false;
    server.id = 'b' * 32;
    await a.sync();
    expect(server.patches, 0);
    expect(a.hidden, isEmpty);
    server.id = 'a' * 32;
    await a.sync();
    expect(server.rows['private-route\u001fmessage']!['hidden'], true);
  });
}
