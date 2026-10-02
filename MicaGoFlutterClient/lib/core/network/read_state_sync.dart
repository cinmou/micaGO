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

  String _encode() =>
      jsonEncode({'serverId': _serverId, 'rows': _rows, 'pending': _pending});
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
    final prior = _publishedPositions;
    if (prior == null ||
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
        if (entry.value >
            max(_rows[entry.key] ?? 0, _pending[entry.key] ?? 0)) {
          _pending[entry.key] = entry.value;
        }
      }
      if (_pending.isEmpty) return;
      await _publish();
      await _sync();
    });
  }

  void _apply(Map<String, dynamic> snapshot) {
    for (final raw in snapshot['data'] as List) {
      final row = raw as Map<String, dynamic>;
      final route = row['chatGuid'] as String;
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
        await cache.writeMetadata('read_state.archived.$_serverId', _encode());
        _rows.clear();
        _pending.clear();
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
      while (_pending.isNotEmpty && identical(client, api())) {
        final batch = Map<String, int>.fromEntries(_pending.entries.take(200));
        final reply = await client.patchReadState({
          'serverId': server,
          'changes': [
            for (final entry in batch.entries)
              {'chatGuid': entry.key, 'readThrough': entry.value},
          ],
        });
        if (!identical(client, api()) || reply['serverId'] != server) return;
        _apply(reply);
        for (final entry in batch.entries) {
          if ((_rows[entry.key] ?? 0) >= entry.value) {
            _pending.remove(entry.key);
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
