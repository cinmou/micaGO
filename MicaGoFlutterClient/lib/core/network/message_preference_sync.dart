import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../storage/local_cache_store.dart';
import 'api_client.dart';

class MessagePreferenceSync extends ChangeNotifier {
  MessagePreferenceSync({
    required this.cache,
    required this.api,
    required this.onChanged,
  });
  final LocalCacheStore cache;
  final ApiClient? Function() api;
  final VoidCallback onChanged;
  Future<void> _serial = Future.value();
  bool _loaded = false;
  bool _disposed = false;
  String? _serverId;
  int _revision = 0;
  final Map<String, Map<String, dynamic>> _rows = {};
  final List<Map<String, dynamic>> _queue = [];
  final List<Map<String, dynamic>> _conflicts = [];
  final Set<String> _legacy = {};
  String? errorKey;
  String? _savedState;
  String? _publishedError;
  Set<String>? _visibleHidden;
  int get legacyCount => _legacy.length;
  bool get hasConflicts => _conflicts.isNotEmpty;
  bool get pending => _queue.isNotEmpty;
  Set<String> get hidden {
    final result = {
      ..._legacy,
      for (final row in _rows.values)
        if (row['hidden'] == true) row['messageKey'] as String,
    };
    for (final mutation in _queue) {
      for (final change
          in (mutation['changes'] as List).cast<Map<String, dynamic>>()) {
        if (change['hidden'] == true) {
          result.add(change['messageKey'] as String);
        } else {
          result.remove(change['messageKey']);
        }
      }
    }
    return result;
  }

  bool isHidden(String guid) => (_visibleHidden ?? hidden).contains(guid);

  Future<void> _run(Future<void> Function() action) {
    final result = _serial.then((_) async {
      await _load();
      if (!_disposed) await action();
    });
    _serial = result.then((_) {}, onError: (Object error, StackTrace stack) {});
    return result;
  }

  Future<void> _load() async {
    if (_loaded) return;
    final raw = await cache.readMetadata('message_preferences.v1');
    if (raw != null && raw.isNotEmpty) {
      final state = jsonDecode(raw) as Map<String, dynamic>;
      _serverId = state['serverId'] as String?;
      _revision = (state['revision'] as num).toInt();
      for (final row in (state['rows'] as List).cast<Map<String, dynamic>>()) {
        _rows[row['messageKey'] as String] = row;
      }
      _queue.addAll((state['queue'] as List).cast<Map<String, dynamic>>());
      _conflicts.addAll(
        (state['conflicts'] as List).cast<Map<String, dynamic>>(),
      );
      _legacy.addAll((state['legacy'] as List).cast<String>());
    } else {
      _legacy.addAll(await cache.hiddenMessageGuids());
      final records = await cache.hiddenMessages();
      for (final key
          in _legacy.where((key) => !key.contains('\u001f')).toList()) {
        final candidates = records
            .where((row) => row.guid == key && row.message != null)
            .map((row) => '${row.message!.chatGuid}\u001f${row.message!.guid}')
            .toSet();
        if (candidates.length == 1) {
          _legacy.remove(key);
          _legacy.add(candidates.single);
        }
      }
    }
    _loaded = true;
    await _publish();
  }

  Future<void> _publish() async {
    final encoded = jsonEncode({
      'serverId': _serverId,
      'revision': _revision,
      'rows': _rows.values.toList(),
      'queue': _queue,
      'conflicts': _conflicts,
      'legacy': _legacy.toList(),
    });
    final changed = encoded != _savedState || errorKey != _publishedError;
    if (encoded != _savedState) {
      await cache.writeMetadata('message_preferences.v1', encoded);
      _savedState = encoded;
    }
    final nextHidden = hidden;
    final visibilityChanged = !setEquals(nextHidden, _visibleHidden);
    if (visibilityChanged) {
      await cache.applyMessageVisibility(nextHidden);
      _visibleHidden = nextHidden;
    }
    _publishedError = errorKey;
    if (!_disposed) {
      if (visibilityChanged) onChanged();
      if (changed) notifyListeners();
    }
  }

  Future<void> initialize() => _run(() async {});
  Future<void> sync() => _run(_sync);
  Future<void> _sync() async {
    final client = api();
    if (client == null) {
      errorKey = 'prefs.offline';
      await _publish();
      return;
    }
    try {
      final snapshot = await client.getMessagePreferences();
      if (!identical(client, api())) return;
      final server = snapshot['serverId'] as String;
      if (_serverId != null && _serverId != server) {
        await cache.writeMetadata(
          'message_preferences.archived.$_serverId',
          jsonEncode({
            'serverId': _serverId,
            'revision': _revision,
            'rows': _rows.values.toList(),
            'queue': _queue,
            'conflicts': _conflicts,
            'legacy': _legacy.toList(),
          }),
        );
        _rows.clear();
        _queue.clear();
        _conflicts.clear();
        _legacy.clear();
        final archived = await cache.readMetadata(
          'message_preferences.archived.$server',
        );
        if (archived != null) {
          final state = jsonDecode(archived) as Map<String, dynamic>;
          _queue.addAll((state['queue'] as List).cast<Map<String, dynamic>>());
          _conflicts.addAll(
            (state['conflicts'] as List).cast<Map<String, dynamic>>(),
          );
          _legacy.addAll((state['legacy'] as List).cast<String>());
        }
      }
      _serverId = server;
      _applySnapshot(snapshot);
      while (_queue.isNotEmpty && identical(client, api())) {
        final mutation = _queue.first;
        try {
          final reply = await client.patchMessagePreferences(mutation);
          final previous = (mutation['changes'] as List)
              .cast<Map<String, dynamic>>();
          _queue.removeAt(0);
          final rows = (reply['data'] as List).cast<Map<String, dynamic>>();
          for (final row in rows) {
            final guid = row['messageKey'] as String;
            if (((_rows[guid]?['revision'] as num?)?.toInt() ?? 0) <=
                (row['revision'] as num).toInt()) {
              _rows[guid] = row;
            }
            final old = previous.firstWhere(
              (p) => p['messageKey'] == guid,
            )['baseRevision'];
            for (final queued in _queue) {
              for (final change
                  in (queued['changes'] as List).cast<Map<String, dynamic>>()) {
                if (change['messageKey'] == guid &&
                    change['baseRevision'] == old) {
                  change['baseRevision'] = row['revision'];
                }
              }
            }
          }
          _revision = max(_revision, (reply['revision'] as num).toInt());
          await _publish();
        } on ApiException catch (e) {
          if (e.statusCode != 409) rethrow;
          final current = await client.getMessagePreferences();
          if (current['serverId'] != _serverId) {
            throw StateError('Preference server changed.');
          }
          _conflicts.add(_queue.removeAt(0));
          _applySnapshot(current);
          await _publish();
        }
      }
      errorKey = hasConflicts ? 'prefs.conflict' : null;
    } catch (_) {
      errorKey = 'prefs.offline';
    }
    await _publish();
  }

  void _applySnapshot(Map<String, dynamic> snapshot) {
    _rows.clear();
    for (final row in (snapshot['data'] as List).cast<Map<String, dynamic>>()) {
      _rows[row['messageKey'] as String] = row;
    }
    _revision = (snapshot['revision'] as num).toInt();
  }

  Future<void> setHidden(Iterable<String> guids, bool value) => _run(() async {
    if (_serverId == null) await _sync();
    if (_serverId == null) {
      throw StateError('Connect once before syncing hidden messages.');
    }
    final requested = guids.toSet();
    if (!value) {
      for (final key in requested) {
        _legacy.remove(key);
        if (key.contains('\u001f')) _legacy.remove(key.split('\u001f').last);
      }
    }
    _enqueue(requested.where((key) => key.split('\u001f').length == 2), value);
    await _publish();
    await _sync();
  });

  void _enqueue(Iterable<String> guids, bool value) {
    final ids = guids.toSet().toList();
    for (var i = 0; i < ids.length; i += 200) {
      final part = ids.skip(i).take(200);
      _queue.add({
        'serverId': _serverId,
        'mutationId': List.generate(
          24,
          (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join(),
        'changes': [
          for (final guid in part)
            {
              'messageKey': guid,
              'hidden': value,
              'baseRevision': _rows[guid]?['revision'] ?? 0,
            },
        ],
      });
    }
    _legacy.removeAll(ids);
  }

  Future<void> registerLocalRecords() => _run(() async {
    _legacy.addAll((await cache.hiddenMessageGuids()).difference(hidden));
    await _publish();
  });

  Future<void> importLegacy() =>
      setHidden(_legacy.where((key) => key.contains('\u001f')).toList(), true);
  Future<void> acceptServer() => _run(() async {
    _conflicts.clear();
    errorKey = null;
    await _publish();
  });
  Future<void> retryConflicts() => _run(() async {
    final desired = <String, bool>{};
    for (final mutation in _conflicts) {
      for (final change
          in (mutation['changes'] as List).cast<Map<String, dynamic>>()) {
        desired[change['messageKey'] as String] = change['hidden'] as bool;
      }
    }
    _conflicts.clear();
    for (final value in [true, false]) {
      _enqueue(desired.keys.where((key) => desired[key] == value), value);
    }
    await _publish();
    await _sync();
  });

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
