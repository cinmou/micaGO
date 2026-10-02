import 'dart:convert';
import 'dart:math';
import '../storage/local_cache_store.dart';
import 'api_client.dart';

/// Read positions form a monotonic MAX register per route; retries commute.
class ReadStateSync {
  ReadStateSync({
    required this.cache,
    required this.api,
    required this.onChanged,
  });
  final LocalCacheStore cache;
  final ApiClient? Function() api;
  final Future<void> Function(Map<String, int>) onChanged;
  Future<void> _serial = Future.value();
  bool _loaded = false;
  String? _serverId;
  String? _savedState;
  Map<String, int>? _publishedPositions;
  final Map<String, int> _rows = {};
  final Map<String, Map<String, dynamic>> _marks = {};
  final Map<String, Map<String, dynamic>> _pendingMarks = {};
  Map<String, bool> get unreadMarks => {
    for (final entry in _marks.entries)
      entry.key: entry.value['markedUnread'] == true,
    for (final entry in _pendingMarks.entries)
      entry.key: entry.value['markedUnread'] == true,
  };
  Map<String, bool>? _publishedMarks;
  final Map<String, int> _pending = {};
  Future<void> _run(Future<void> Function() action) {
    final result = _serial.then((_) async {
      await _load();
      await action();
    });
    _serial = result.then((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _load() async {
    if (_loaded) return;
    final raw = await cache.readMetadata('read_state.v1');
    if (raw != null) _decode(jsonDecode(raw) as Map<String, dynamic>);
    _loaded = true;
  }

  void _decode(Map<String, dynamic> state) {
    _serverId = state['serverId'] as String?;
    _rows.clear();
    _pending.clear();
    _marks.clear();
    _pendingMarks.clear();
    for (final entry in ((state['marks'] as Map?) ?? {}).entries) {
      _marks[entry.key as String] = Map<String, dynamic>.from(
        entry.value as Map,
      );
    }
    for (final entry in ((state['pendingMarks'] as Map?) ?? {}).entries) {
      _pendingMarks[entry.key as String] = Map<String, dynamic>.from(
        entry.value as Map,
      );
    }
    _rows.addAll(
      (state['rows'] as Map).map(
        (k, v) => MapEntry(k as String, (v as num).toInt()),
      ),
    );
    _pending.addAll(
      (state['pending'] as Map).map(
        (k, v) => MapEntry(k as String, (v as num).toInt()),
      ),
    );
  }

  String _encode() => jsonEncode({
    'serverId': _serverId,
    'rows': _rows,
    'pending': _pending,
    'marks': _marks,
    'pendingMarks': _pendingMarks,
  });
  Future<void> _publish() async {
    final encoded = _encode();
    if (encoded != _savedState) {
      await cache.writeMetadata('read_state.v1', encoded);
      _savedState = encoded;
    }
    final effective = Map<String, int>.of(_rows);
    for (final entry in _pending.entries) {
      effective[entry.key] = max(effective[entry.key] ?? 0, entry.value);
    }
    await cache.applyReadPositions(effective);
    final marks = unreadMarks;
    await cache.applyUnreadMarks(marks);
    final marksChanged =
        _publishedMarks == null ||
        _publishedMarks!.length != marks.length ||
        marks.entries.any((e) => _publishedMarks![e.key] != e.value);
    _publishedMarks = Map.of(marks);
    final prior = _publishedPositions;
    if (marksChanged ||
        prior == null ||
        prior.length != effective.length ||
        effective.entries.any((entry) => prior[entry.key] != entry.value)) {
      _publishedPositions = Map.of(effective);
      await onChanged(effective);
    }
  }

  Future<void> sync() => _run(_sync);
  Future<void> markViewed(Map<String, int> positions) {
    final expected = api();
    return _run(() async {
      final server = _serverId;
      // Unscoped local history is never uploaded to a newly paired server.
      if (_serverId == null) await _sync();
      if (_serverId == null ||
          !identical(expected, api()) ||
          (server != null && server != _serverId)) {
        return;
      }
      for (final entry in positions.entries) {
        if (unreadMarks[entry.key] == true ||
            _pendingMarks.containsKey(entry.key)) {
          _pendingMarks[entry.key] = {
            'markedUnread': false,
            'baseUnreadRevision': _marks[entry.key]?['unreadRevision'] ?? 0,
          };
        }
        if (entry.value >
            max(_rows[entry.key] ?? 0, _pending[entry.key] ?? 0)) {
          _pending[entry.key] = entry.value;
        }
      }
      if (_pending.isEmpty && _pendingMarks.isEmpty) return;
      await _publish();
      await _sync();
    });
  }

  Future<void> markUnread(Iterable<String> routes) => _run(() async {
    final client = api();
    final scopedServer = _serverId;
    if (_serverId == null) await _sync();
    if (_serverId == null ||
        !identical(client, api()) ||
        (scopedServer != null && scopedServer != _serverId)) {
      return;
    }
    for (final route in routes.toSet()) {
      _pendingMarks[route] = {
        'markedUnread': true,
        'baseUnreadRevision': _marks[route]?['unreadRevision'] ?? 0,
      };
    }
    await _publish();
    await _sync();
  });

  void _apply(Map<String, dynamic> snapshot) {
    for (final raw in snapshot['data'] as List) {
      final row = raw as Map<String, dynamic>;
      final route = row['chatGuid'] as String;
      if (row.containsKey('markedUnread') &&
          (row['unreadRevision'] as num? ?? 0) >=
              (_marks[route]?['unreadRevision'] as num? ?? 0)) {
        _marks[route] = {
          'markedUnread': row['markedUnread'],
          'unreadRevision': row['unreadRevision'] ?? 0,
        };
      }
      _rows[route] = max(
        _rows[route] ?? 0,
        (row['readThrough'] as num).toInt(),
      );
    }
  }

  Future<void> _sync() async {
    final client = api();
    if (client == null) return;
    try {
      final snapshot = await client.getReadState();
      if (!identical(client, api())) return;
      final server = snapshot['serverId'] as String;
      if (_serverId != null && _serverId != server) {
        await cache.applyUnreadMarks({
          for (final route in unreadMarks.keys) route: false,
        });
        await cache.writeMetadata('read_state.archived.$_serverId', _encode());
        _rows.clear();
        _pending.clear();
        _marks.clear();
        _pendingMarks.clear();
        final archived = await cache.readMetadata(
          'read_state.archived.$server',
        );
        if (archived != null) {
          _decode(jsonDecode(archived) as Map<String, dynamic>);
        }
      }
      _serverId = server;
      _apply(snapshot);
      await _publish();
      while ((_pending.isNotEmpty || _pendingMarks.isNotEmpty) &&
          identical(client, api())) {
        final routes = {
          ..._pending.keys,
          ..._pendingMarks.keys,
        }.take(200).toList();
        final batch = {
          for (final route in routes)
            route: _pending[route] ?? _rows[route] ?? 0,
        };
        final markBatch = {
          for (final route in routes)
            if (_pendingMarks.containsKey(route))
              route: Map<String, dynamic>.of(_pendingMarks[route]!),
        };
        final reply = await client.patchReadState({
          'serverId': server,
          'changes': [
            for (final entry in batch.entries)
              {
                'chatGuid': entry.key,
                'readThrough': entry.value,
                ...?markBatch[entry.key],
              },
          ],
        });
        if (!identical(client, api()) || reply['serverId'] != server) return;
        _apply(reply);
        for (final entry in batch.entries) {
          if ((_rows[entry.key] ?? 0) >= entry.value) {
            _pending.remove(entry.key);
          }
        }
        for (final entry in markBatch.entries) {
          final current = _marks[entry.key];
          if (current != null &&
              ((current['unreadRevision'] as int) >
                      (entry.value['baseUnreadRevision'] as int) ||
                  current['markedUnread'] == entry.value['markedUnread'])) {
            _pendingMarks.remove(entry.key);
          } else {
            // An older backend cannot acknowledge manual marks. Retain them
            // without spinning or pretending that synchronization succeeded.
            await _publish();
            return;
          }
        }
        await _publish();
      }
    } on ApiException catch (_) {
      /* Retain the durable outbox for retry. */
    } on Exception catch (_) {
      /* Network/storage failures are best effort. */
    }
  }
}
