import 'dart:convert';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mica_go/core/network/api_client.dart';
import 'package:mica_go/core/network/read_state_sync.dart';
import 'package:mica_go/core/storage/local_cache_store.dart';

class ReadCache extends LocalCacheStore {
  final metadata = <String, String>{};
  final seen = <String, int>{};
  final marks = <String, bool>{};
  @override
  Future<void> applyUnreadMarks(Map<String, bool> values) async {
    marks.addAll(values);
  }

  @override
  Future<String?> readMetadata(String key) async => metadata[key];
  @override
  Future<void> writeMetadata(String key, String value) async {
    metadata[key] = value;
  }

  @override
  Future<void> applyReadPositions(Map<String, int> positions) async {
    for (final entry in positions.entries) {
      seen[entry.key] = max(seen[entry.key] ?? 0, entry.value);
    }
  }
}

class ReadServer {
  String id = 'a' * 32;
  bool offline = false, loseReply = false;
  final servers = <String, Map<String, int>>{};
  Map<String, int> get rows => servers.putIfAbsent(id, () => {});
  final markStores = <String, Map<String, Map<String, dynamic>>>{};
  Map<String, Map<String, dynamic>> get marks =>
      markStores.putIfAbsent(id, () => {});
  final sentScopes = <String>[];
  Map<String, dynamic> get snapshot => {
    'serverId': id,
    'revision': 0,
    'data': [
      for (final route in {...rows.keys, ...marks.keys})
        {
          'chatGuid': route,
          'readThrough': rows[route] ?? 0,
          'markedUnread': marks[route]?['markedUnread'] ?? false,
          'unreadRevision': marks[route]?['unreadRevision'] ?? 0,
        },
    ],
  };
  late final client = ApiClient(
    baseUrl: 'http://test',
    token: 'test',
    httpClient: MockClient((request) async {
      if (offline) throw http.ClientException('offline');
      expect(request.url.path, '/api/read-state');
      if (request.method == 'PATCH') {
        final mutation = jsonDecode(request.body) as Map<String, dynamic>;
        sentScopes.add(mutation['serverId'] as String);
        if (mutation['serverId'] != id) return http.Response('{}', 409);
        for (final row in mutation['changes'] as List) {
          final route = row['chatGuid'] as String;
          final mark = marks.putIfAbsent(
            route,
            () => {'markedUnread': false, 'unreadRevision': 0},
          );
          if (row.containsKey('markedUnread') &&
              row['baseUnreadRevision'] != mark['unreadRevision']) {
            continue;
          }
          final at = row['readThrough'] as int;
          if (at > (rows[route] ?? 0)) {
            rows[route] = at;
            mark['markedUnread'] = false;
            mark['unreadRevision'] = (mark['unreadRevision'] as int) + 1;
          }
          if (row.containsKey('markedUnread') &&
              row['markedUnread'] != mark['markedUnread']) {
            mark['markedUnread'] = row['markedUnread'];
            mark['unreadRevision'] = (mark['unreadRevision'] as int) + 1;
          }
        }
        if (loseReply) {
          loseReply = false;
          throw http.ClientException('lost acknowledgement');
        }
      }
      return http.Response(jsonEncode(snapshot), 200);
    }),
  );
  ReadStateSync device(ReadCache cache) =>
      ReadStateSync(cache: cache, api: () => client, onChanged: (_) async {});
}

void main() {
  test(
    'manual unread syncs without rewinding and clears on the other device',
    () async {
      final server = ReadServer(), aCache = ReadCache(), bCache = ReadCache();
      final a = server.device(aCache), b = server.device(bCache);
      await a.sync();
      await b.sync();
      await a.markViewed({'a': 200, 'b': 100});
      await a.markUnread(['a', 'b']);
      await b.sync();
      expect(bCache.marks, {'a': true, 'b': true});
      expect(bCache.seen, {'a': 200, 'b': 100});
      await b.markViewed({'a': 200});
      await a.sync();
      expect(aCache.marks, {'a': false, 'b': true});
      expect(server.rows['a'], 200);
    },
  );
  test(
    'offline unread survives restart and stale replay cannot undo a newer read',
    () async {
      final server = ReadServer(), cache = ReadCache();
      var a = server.device(cache);
      await a.sync();
      await a.markViewed({'a': 200});
      server.offline = true;
      await a.markUnread(['a']);
      expect(cache.marks['a'], true);
      server.offline = false;
      final b = server.device(ReadCache());
      await b.sync();
      await b.markViewed({'a': 300});
      a = server.device(cache);
      await a.sync();
      expect(cache.marks['a'], false);
      expect(cache.seen['a'], 300);
      await a.markUnread(['a']);
      server.loseReply = true;
      await a.markViewed({'a': 300});
      await a.sync();
      expect(cache.marks['a'], false);
    },
  );

  test(
    'read positions sync across devices, remain monotonic and route scoped',
    () async {
      final server = ReadServer(), aCache = ReadCache(), bCache = ReadCache();
      final a = server.device(aCache), b = server.device(bCache);
      await a.sync();
      await b.sync();
      await a.markViewed({'route-a': 200, 'route-b': 50});
      await b.sync();
      expect(bCache.seen, {'route-a': 200, 'route-b': 50});
      await b.markViewed({'route-a': 100});
      await a.sync();
      expect(server.rows['route-a'], 200);
      expect(server.rows['route-b'], 50);
    },
  );
  test('offline read survives restart and lost acknowledgements', () async {
    final server = ReadServer(), cache = ReadCache();
    var a = server.device(cache);
    await a.sync();
    server.offline = true;
    await a.markViewed({'a': 200});
    await a.markViewed({'a': 100});
    expect(cache.seen['a'], 200);
    a = server.device(cache);
    server.offline = false;
    server.loseReply = true;
    await a.sync();
    await a.sync();
    expect(server.rows['a'], 200);
    expect(
      (jsonDecode(cache.metadata['read_state.v1']!) as Map)['pending'],
      isEmpty,
    );
  });
  test(
    'switching servers archives pending reads and restores the original scope',
    () async {
      final server = ReadServer(), cache = ReadCache();
      final a = server.device(cache);
      await a.sync();
      server.offline = true;
      await a.markViewed({'private': 200});
      server.offline = false;
      server.id = 'b' * 32;
      await a.sync();
      expect(server.rows, isEmpty);
      expect(server.sentScopes, isEmpty);
      server.id = 'a' * 32;
      await a.sync();
      expect(server.rows['private'], 200);
    },
  );
  test('first offline connection never uploads unscoped cache reads', () async {
    final server = ReadServer()..offline = true;
    final a = server.device(ReadCache());
    await a.markViewed({'foreign': 999});
    server.offline = false;
    await a.sync();
    expect(server.rows, isEmpty);
  });
}
