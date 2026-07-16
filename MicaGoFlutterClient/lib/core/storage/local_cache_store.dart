import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../features/chats/message_render.dart'
    show messagePreviewText, reactionTargetGuid;
import '../../features/chats/models/chat_summary.dart';
import '../../features/chats/models/message_model.dart';

class LocalCacheStore {
  Database? _db;
  String? _path;

  // Bump on any schema OR pipeline-semantics change. C12 (v2): the server now
  // ships a single canonical renderable timeline. Bump this when renderability
  // semantics change, because cached JSON may carry old attachment/noise rows
  // even after the server has learned to filter them.
  // v4: chats.pinned + a hidden_messages tombstone table (C42 pin/hide).
  // v5: chats.last_seen_at + chats.latest_from_me drive the watermark-derived
  // unread dot (C43) — unread is computed from the data, not a fragile counter.
  static const int _schemaVersion = 5;

  Future<void> open() async {
    if (_db != null) return;
    final dir = await getDatabasesPath();
    _path = p.join(dir, 'micago_client_cache.db');
    _db = await openDatabase(
      _path!,
      version: _schemaVersion,
      onCreate: (db, _) => _createSchema(db),
      onUpgrade: (db, _, _) => _rebuildSchema(db),
      onDowngrade: (db, _, _) => _rebuildSchema(db),
    );
  }

  String? get databasePath => _path;
  int get schemaVersion => _schemaVersion;

  Future<void> _createSchema(Database db) async {
    await db.execute('''
CREATE TABLE chats (
  guid TEXT PRIMARY KEY,
  json TEXT NOT NULL,
  latest_renderable_at INTEGER,
  hidden INTEGER NOT NULL DEFAULT 0,
  always_visible INTEGER NOT NULL DEFAULT 0,
  pinned INTEGER NOT NULL DEFAULT 0,
  last_seen_at INTEGER NOT NULL DEFAULT 0,
  latest_from_me INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL
);
''');
    // Tombstones for client-side message hiding. Kept out of the messages table
    // so a server re-sync (delete + reinsert) never resurrects a hidden message.
    await db.execute('''
CREATE TABLE hidden_messages (
  guid TEXT PRIMARY KEY
);
''');
    await db.execute('''
CREATE TABLE messages (
  key TEXT PRIMARY KEY,
  guid TEXT,
  temp_id TEXT,
  chat_guid TEXT NOT NULL,
  json TEXT NOT NULL,
  local_state TEXT NOT NULL,
  date_created INTEGER,
  updated_at INTEGER NOT NULL
);
''');
    await db.execute(
      'CREATE INDEX messages_chat_date ON messages(chat_guid, date_created);',
    );
    await db.execute('CREATE INDEX messages_guid ON messages(guid);');
    await db.execute('CREATE INDEX messages_temp ON messages(temp_id);');
    await db.execute('''
CREATE TABLE metadata (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
''');
  }

  // Destructive rebuild: discard any rows persisted under an older pipeline so
  // pre-C12 noise rows cannot survive, then recreate the current schema.
  Future<void> _rebuildSchema(Database db) async {
    await db.execute('DROP TABLE IF EXISTS messages;');
    await db.execute('DROP TABLE IF EXISTS chats;');
    await db.execute('DROP TABLE IF EXISTS metadata;');
    await db.execute('DROP TABLE IF EXISTS hidden_messages;');
    await _createSchema(db);
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  Future<void> clearAll() async {
    final db = await _ready();
    await db.delete('messages');
    await db.delete('chats');
    await db.delete('metadata');
  }

  Future<List<ChatSummary>> listChats({
    bool includeDebug = false,
    bool includeHidden = false,
  }) async {
    final db = await _ready();
    // Pinned chats sort to the top; within each group, newest activity first.
    final rows = await db.query(
      'chats',
      orderBy:
          'pinned DESC, COALESCE(latest_renderable_at, 0) DESC, updated_at DESC',
    );
    return rows
        .map(_chatFromRow)
        .where((chat) => includeDebug || chat.hasRenderableMessages)
        .where((chat) => includeHidden || !_isHiddenRow(rows, chat.guid))
        .toList(growable: false);
  }

  Future<void> upsertChats(Iterable<ChatSummary> chats) async {
    final db = await _ready();
    final existingRows = await db.query(
      'chats',
      columns: const ['guid', 'json'],
    );
    final existingUnread = <String, int>{};
    for (final row in existingRows) {
      final guid = row['guid'] as String?;
      if (guid == null) continue;
      try {
        final raw = jsonDecode(row['json'] as String) as Map<String, dynamic>;
        final count = ChatSummary.fromJson(raw).unreadCount;
        if (count != null && count > 0) existingUnread[guid] = count;
      } catch (_) {
        // Ignore corrupt cache rows; the fresh server row will replace them.
      }
    }
    final batch = db.batch();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final chat in chats) {
      final mergedUnread = chat.unreadCount ?? existingUnread[chat.guid];
      final next = mergedUnread == null
          ? chat
          : chat.copyWith(unreadCount: mergedUnread);
      // ON CONFLICT DO UPDATE (not REPLACE) so the local flag columns survive a
      // server refresh. last_seen_at is set ONLY on first insert (= the chat's
      // current latest) so existing history starts "seen" — it is intentionally
      // absent from the UPDATE clause so later messages become unread.
      batch.rawInsert(
        '''
INSERT INTO chats (guid, json, latest_renderable_at, latest_from_me, last_seen_at, updated_at)
VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT(guid) DO UPDATE SET
  json = excluded.json,
  latest_renderable_at = excluded.latest_renderable_at,
  latest_from_me = excluded.latest_from_me,
  updated_at = excluded.updated_at
''',
        [
          next.guid,
          jsonEncode(next.toJson()),
          next.lastMessageAt,
          next.latestFromMe ? 1 : 0,
          next.lastMessageAt ?? 0,
          now,
        ],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> removeChats(Iterable<String> guids) async {
    final ids = guids.where((g) => g.trim().isNotEmpty).toSet();
    if (ids.isEmpty) return;
    final db = await _ready();
    final batch = db.batch();
    for (final guid in ids) {
      batch.delete('messages', where: 'chat_guid = ?', whereArgs: [guid]);
      batch.delete('chats', where: 'guid = ?', whereArgs: [guid]);
    }
    await batch.commit(noResult: true);
  }

  Future<void> setChatHidden(String guid, bool hidden) async {
    final db = await _ready();
    await db.update(
      'chats',
      {'hidden': hidden ? 1 : 0},
      where: 'guid = ?',
      whereArgs: [guid],
    );
  }

  /// Forces a noise-only chat to stay visible (overrides the renderable filter).
  Future<void> setChatAlwaysVisible(String guid, bool visible) async {
    final db = await _ready();
    await db.update(
      'chats',
      {'always_visible': visible ? 1 : 0},
      where: 'guid = ?',
      whereArgs: [guid],
    );
  }

  // C42: pin/hide management. pinned/hidden live in columns so a server upsert
  // (which only rewrites the json blob) never resets them.

  Future<void> setChatPinned(String guid, bool pinned) async {
    final db = await _ready();
    await db.update(
      'chats',
      {'pinned': pinned ? 1 : 0},
      where: 'guid = ?',
      whereArgs: [guid],
    );
  }

  /// Number of user-hidden chats (excludes always-visible overrides).
  Future<int> hiddenChatCount() async {
    final db = await _ready();
    final r = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM chats WHERE hidden = 1 AND always_visible = 0',
    );
    return (r.first['n'] as int?) ?? 0;
  }

  Future<List<ChatSummary>> hiddenChats() async {
    final db = await _ready();
    final rows = await db.query(
      'chats',
      where: 'hidden = 1 AND always_visible = 0',
      orderBy:
          'COALESCE(latest_renderable_at, 0) DESC, updated_at DESC, guid ASC',
    );
    return rows.map(_chatFromRow).toList(growable: false);
  }

  Future<int> releaseHiddenChats(Iterable<String> guids) async {
    final ids = guids.where((g) => g.trim().isNotEmpty).toSet();
    if (ids.isEmpty) return 0;
    final db = await _ready();
    final batch = db.batch();
    for (final guid in ids) {
      batch.update(
        'chats',
        {'hidden': 0},
        where: 'guid = ?',
        whereArgs: [guid],
      );
    }
    final results = await batch.commit();
    return results.whereType<int>().fold<int>(0, (sum, value) => sum + value);
  }

  /// Hides a single message on the client only (a tombstone; the server copy is
  /// untouched). Idempotent.
  Future<void> setMessageHidden(String guid, bool hidden) async {
    if (guid.isEmpty) return;
    final db = await _ready();
    if (hidden) {
      await db.insert('hidden_messages', {
        'guid': guid,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    } else {
      await db.delete('hidden_messages', where: 'guid = ?', whereArgs: [guid]);
    }
  }

  Future<int> hiddenMessageCount() async {
    final db = await _ready();
    final r = await db.rawQuery('SELECT COUNT(*) AS n FROM hidden_messages');
    return (r.first['n'] as int?) ?? 0;
  }

  Future<List<HiddenMessageRecord>> hiddenMessages() async {
    final db = await _ready();
    final rows = await db.rawQuery('''
SELECT
  hm.guid AS hidden_guid,
  m.json AS message_json,
  m.chat_guid AS chat_guid,
  c.json AS chat_json
FROM hidden_messages hm
LEFT JOIN messages m ON m.guid = hm.guid
LEFT JOIN chats c ON c.guid = m.chat_guid
ORDER BY COALESCE(m.date_created, 0) DESC, hm.guid ASC
''');
    return rows
        .map((row) {
          MessageModel? message;
          ChatSummary? chat;
          final messageJson = row['message_json'] as String?;
          if (messageJson != null && messageJson.isNotEmpty) {
            try {
              message = MessageModel.fromJson(
                (jsonDecode(messageJson) as Map).cast<String, dynamic>(),
              );
            } catch (_) {
              message = null;
            }
          }
          final chatJson = row['chat_json'] as String?;
          if (chatJson != null && chatJson.isNotEmpty) {
            try {
              chat = ChatSummary.fromJson(
                (jsonDecode(chatJson) as Map).cast<String, dynamic>(),
              );
            } catch (_) {
              chat = null;
            }
          }
          return HiddenMessageRecord(
            guid: row['hidden_guid'] as String,
            message: message,
            chat: chat,
          );
        })
        .toList(growable: false);
  }

  /// The set of client-hidden message guids, to filter server-fetched pages that
  /// bypass the cache read.
  Future<Set<String>> hiddenMessageGuids() async {
    final db = await _ready();
    final rows = await db.query('hidden_messages', columns: const ['guid']);
    return {for (final r in rows) r['guid'] as String};
  }

  Future<int> releaseHiddenMessages(Iterable<String> guids) async {
    final ids = guids.where((g) => g.trim().isNotEmpty).toSet();
    if (ids.isEmpty) return 0;
    final db = await _ready();
    final batch = db.batch();
    for (final guid in ids) {
      batch.delete('hidden_messages', where: 'guid = ?', whereArgs: [guid]);
    }
    final results = await batch.commit();
    return results.whereType<int>().fold<int>(0, (sum, value) => sum + value);
  }

  Future<List<MessageModel>> listMessages(
    String chatGuid, {
    int limit = 200,
  }) async {
    final db = await _ready();
    // Exclude client-hidden messages (tombstoned in hidden_messages).
    final rows = await db.query(
      'messages',
      where:
          'chat_guid = ? AND (guid IS NULL OR guid NOT IN (SELECT guid FROM hidden_messages))',
      whereArgs: [chatGuid],
      orderBy: 'date_created DESC, updated_at DESC',
      limit: limit,
    );
    return rows.map(_messageFromRow).toList(growable: false);
  }

  /// Every locally persisted message for a chat, newest first. Details/media
  /// aggregation uses this instead of the thread's bounded in-memory window.
  Future<List<MessageModel>> listAllMessages(String chatGuid) async {
    final db = await _ready();
    final rows = await db.query(
      'messages',
      where:
          'chat_guid = ? AND (guid IS NULL OR guid NOT IN (SELECT guid FROM hidden_messages))',
      whereArgs: [chatGuid],
      orderBy: 'date_created DESC, updated_at DESC',
    );
    return rows.map(_messageFromRow).toList(growable: false);
  }

  Future<bool> hasMessageGuid(String guid) async {
    if (guid.isEmpty) return false;
    final db = await _ready();
    final rows = await db.query(
      'messages',
      columns: const ['key'],
      where: 'guid = ?',
      whereArgs: [guid],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> replaceServerPage(
    String chatGuid,
    Iterable<MessageModel> messages,
  ) async {
    final db = await _ready();
    final batch = db.batch();
    batch.delete(
      'messages',
      where: "chat_guid = ? AND (temp_id IS NULL OR temp_id = '')",
      whereArgs: [chatGuid],
    );
    _batchUpsertMessages(batch, chatGuid, messages);
    await batch.commit(noResult: true);
  }

  /// Adds or updates a fetched page without dropping older cached history.
  /// Thread refreshes use this so media fetched through pagination remains
  /// available to the details aggregation after the next refresh.
  Future<void> mergeServerPage(
    String chatGuid,
    Iterable<MessageModel> messages,
  ) async {
    final db = await _ready();
    final batch = db.batch();
    _batchUpsertMessages(batch, chatGuid, messages);
    await batch.commit(noResult: true);
  }

  Future<void> upsertMessage(String chatGuid, MessageModel message) async {
    final db = await _ready();
    final batch = db.batch();
    _batchUpsertMessages(batch, chatGuid, [message]);
    await batch.commit(noResult: true);
  }

  /// Advances a chat's latest-message state from an incoming/outgoing message.
  ///
  /// [seen] (the message is mine OR its chat is open) also advances the read
  /// watermark so the chat does not light an unread dot; otherwise the watermark
  /// is left behind so the chat reads as unread (C43). [markUnread] only bumps
  /// the auxiliary numeric count — the dot itself is derived from the watermark.
  Future<bool> bumpChatWithMessage(
    MessageModel message, {
    bool markUnread = false,
    bool seen = false,
  }) async {
    final chatGuid = message.chatGuid;
    if (chatGuid == null || chatGuid.isEmpty) return false;
    final db = await _ready();
    final rows = await db.query(
      'chats',
      where: 'guid = ?',
      whereArgs: [chatGuid],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final chat = _chatFromRow(rows.first);
    final at = message.dateCreated;
    if (at == null) return true;
    final current = chat.lastMessageAt ?? 0;
    if (at < current) return true;
    final unreadCount = seen
        ? 0
        : markUnread
        ? (chat.unreadCount ?? 0) + 1
        : chat.unreadCount;
    final bumped = chat.copyWith(
      lastMessageAt: at,
      lastMessagePreview: _previewForMessage(message),
      unreadCount: unreadCount,
      latestFromMe: message.isFromMe,
      hasRenderableMessages: true,
      unsupportedOnly: false,
      hiddenReason: '',
    );
    final values = <String, Object?>{
      'json': jsonEncode(bumped.toJson()),
      'latest_renderable_at': at,
      'latest_from_me': message.isFromMe ? 1 : 0,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    // Only advance the watermark when the user has effectively seen it.
    if (seen) values['last_seen_at'] = at;
    await db.update('chats', values, where: 'guid = ?', whereArgs: [chatGuid]);
    return true;
  }

  /// Marks chats as read: the watermark catches up to the latest message, which
  /// clears the derived unread dot, and the auxiliary count is zeroed. Called on
  /// chat open, mark-as-read, and the drag-to-dismiss badge gesture (C43).
  ///
  /// [upTo] (C47) advances the watermark to at least that timestamp even if the
  /// chat row's `latest_renderable_at` has not yet been bumped for the message
  /// the caller just observed. This makes "the open thread marks itself read"
  /// independent of whether the chat-list ingestion (which writes
  /// `latest_renderable_at`) or this call wins the race for the same WS/delta
  /// event — otherwise the watermark could settle behind the new message and
  /// leave a stale dot lit while the user is looking at the conversation.
  Future<void> markChatsSeen(Iterable<String> guids, {int? upTo}) async {
    final db = await _ready();
    final batch = db.batch();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final guid in guids) {
      final rows = await db.query(
        'chats',
        where: 'guid = ?',
        whereArgs: [guid],
        limit: 1,
      );
      if (rows.isEmpty) continue;
      final latestAt = (rows.first['latest_renderable_at'] as int?) ?? 0;
      final lastSeenAt = (rows.first['last_seen_at'] as int?) ?? 0;
      // Never regress the watermark; cover a not-yet-bumped arrival via [upTo].
      final seenAt = [
        latestAt,
        lastSeenAt,
        upTo ?? 0,
      ].reduce((a, b) => a > b ? a : b);
      final chat = _chatFromRow(rows.first).copyWith(unreadCount: 0);
      batch.update(
        'chats',
        {
          'json': jsonEncode(chat.toJson()),
          'last_seen_at': seenAt,
          'updated_at': now,
        },
        where: 'guid = ?',
        whereArgs: [guid],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> addPending(String chatGuid, MessageModel message) async {
    await upsertMessage(chatGuid, message);
  }

  Future<void> setPendingState(String tempId, LocalSendState state) async {
    final db = await _ready();
    final rows = await db.query(
      'messages',
      where: 'temp_id = ?',
      whereArgs: [tempId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final msg = _messageFromRow(rows.first).copyWith(localState: state);
    await db.update(
      'messages',
      {
        'json': jsonEncode(msg.toJson()),
        'local_state': state.name,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'temp_id = ?',
      whereArgs: [tempId],
    );
  }

  Future<void> deletePending(String tempId) async {
    final db = await _ready();
    await db.delete('messages', where: 'temp_id = ?', whereArgs: [tempId]);
  }

  Future<void> confirmPending(
    String chatGuid,
    String tempId,
    MessageModel server,
  ) async {
    final db = await _ready();
    final batch = db.batch();
    batch.delete('messages', where: 'temp_id = ?', whereArgs: [tempId]);
    _batchUpsertMessages(batch, chatGuid, [server]);
    await batch.commit(noResult: true);
  }

  Future<void> applyUnsend(
    String chatGuid,
    String guid,
    int? dateRetracted,
  ) async {
    final db = await _ready();
    final rows = await db.query(
      'messages',
      where: 'guid = ?',
      whereArgs: [guid],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final msg = _messageFromRow(rows.first).copyWith(
      text: '',
      attachments: const [],
      isRetracted: true,
      dateRetracted: dateRetracted,
      errorCode: 0,
      localState: LocalSendState.confirmed,
    );
    await upsertMessage(chatGuid, msg);
  }

  Future<bool> applyReactionEvent(String chatGuid, MessageModel event) async {
    final targetGuid = reactionTargetGuid(event.associatedMessageGuid);
    if (targetGuid == null) return false;
    final db = await _ready();
    final rows = await db.query(
      'messages',
      where: 'guid = ?',
      whereArgs: [targetGuid],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final target = _messageFromRow(rows.first);
    final reaction = ReactionModel(
      type: _reactionType(event),
      fromHandle: event.handleId,
      isFromMe: event.isFromMe,
      eventGuid: event.guid,
      createdAt: event.dateCreated,
    );
    final filtered = target.reactions
        .where(
          (r) =>
              !(r.type == reaction.type &&
                  r.fromHandle == reaction.fromHandle &&
                  r.isFromMe == reaction.isFromMe),
        )
        .toList(growable: true);
    final next = target.copyWith(
      reactions: _isReactionAdd(event) ? [...filtered, reaction] : filtered,
      localState: LocalSendState.confirmed,
    );
    await upsertMessage(chatGuid, next);
    return true;
  }

  Future<void> writeMetadata(String key, String value) async {
    final db = await _ready();
    await db.insert('metadata', {
      'key': key,
      'value': value,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> readMetadata(String key) async {
    final db = await _ready();
    final rows = await db.query(
      'metadata',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<Map<String, String>> readMetadataWithPrefix(String prefix) async {
    final db = await _ready();
    final rows = await db.query(
      'metadata',
      columns: const ['key', 'value'],
      where: 'key LIKE ?',
      whereArgs: ['$prefix%'],
    );
    return {
      for (final row in rows)
        if (row['key'] is String && row['value'] is String)
          row['key'] as String: row['value'] as String,
    };
  }

  Future<void> deleteMetadata(String key) async {
    final db = await _ready();
    await db.delete('metadata', where: 'key = ?', whereArgs: [key]);
  }

  /// Per-chat local UI flags (pinned / hidden / always-visible) for chats that
  /// have any set, keyed by guid — used by settings backup (C54).
  Future<Map<String, Map<String, int>>> exportChatFlags() async {
    final db = await _ready();
    final rows = await db.query(
      'chats',
      columns: const ['guid', 'pinned', 'hidden', 'always_visible'],
      where: 'pinned = 1 OR hidden = 1 OR always_visible = 1',
    );
    return {
      for (final r in rows)
        (r['guid'] as String): {
          'pinned': (r['pinned'] as int?) ?? 0,
          'hidden': (r['hidden'] as int?) ?? 0,
          'always_visible': (r['always_visible'] as int?) ?? 0,
        },
    };
  }

  /// Applies restored per-chat flags to whichever chat rows already exist,
  /// removing each from the pending set once applied (C54). Safe to call after
  /// every chat sync — flags land as the chats appear, then the pending set
  /// empties so a later user change is never overwritten.
  Future<void> applyPendingChatFlags() async {
    final raw = await readMetadata(_pendingChatFlagsKey);
    if (raw == null || raw.isEmpty) return;
    Map<String, dynamic> pending;
    try {
      pending = (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      await deleteMetadata(_pendingChatFlagsKey);
      return;
    }
    if (pending.isEmpty) {
      await deleteMetadata(_pendingChatFlagsKey);
      return;
    }
    final db = await _ready();
    final existing = <String>{
      for (final r in await db.query('chats', columns: const ['guid']))
        r['guid'] as String,
    };
    final remaining = <String, dynamic>{};
    for (final entry in pending.entries) {
      if (!existing.contains(entry.key)) {
        remaining[entry.key] =
            entry.value; // chat not synced yet — keep waiting
        continue;
      }
      final flags = (entry.value as Map).cast<String, dynamic>();
      await db.update(
        'chats',
        {
          'pinned': (flags['pinned'] as int?) ?? 0,
          'hidden': (flags['hidden'] as int?) ?? 0,
          'always_visible': (flags['always_visible'] as int?) ?? 0,
        },
        where: 'guid = ?',
        whereArgs: [entry.key],
      );
    }
    if (remaining.isEmpty) {
      await deleteMetadata(_pendingChatFlagsKey);
    } else {
      await writeMetadata(_pendingChatFlagsKey, jsonEncode(remaining));
    }
  }

  static const _pendingChatFlagsKey = 'pending_restore_chat_flags';

  /// Stores restored chat flags to be applied as the chats sync in (C54).
  Future<void> setPendingChatFlags(Map<String, Map<String, int>> flags) async {
    if (flags.isEmpty) return;
    await writeMetadata(_pendingChatFlagsKey, jsonEncode(flags));
  }

  Future<Map<String, Object?>> diagnostics() async {
    final db = await _ready();
    Future<int> count(String table) async =>
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM $table'),
        ) ??
        0;
    return {
      'path': _path,
      'schemaVersion': _schemaVersion,
      'chatCount': await count('chats'),
      'messageCount': await count('messages'),
      'attachmentMetadataCount':
          int.tryParse(
            await readMetadata('last_attachment_metadata_count') ?? '',
          ) ??
          0,
      'pendingSendCount':
          Sqflite.firstIntValue(
            await db.rawQuery(
              "SELECT COUNT(*) FROM messages WHERE local_state != 'confirmed'",
            ),
          ) ??
          0,
      'lastBootstrapTime': await readMetadata('last_bootstrap_time'),
      'lastCatchUpTime': await readMetadata('last_catch_up_time'),
      'lastWriteCount': await readMetadata('last_write_count'),
      'lastError': await readMetadata('last_error'),
      'lastAppliedEventCursor': await readMetadata('last_applied_event_cursor'),
      'lastEventAt': await readMetadata('last_event_at'),
      'lastReconnectAt': await readMetadata('last_reconnect_at'),
      'lastCatchUpCursor': await readMetadata('last_catch_up_cursor'),
      'lastCatchUpResultCount': await readMetadata(
        'last_catch_up_result_count',
      ),
      'eventsPatchedDirectly':
          await readMetadata('events_patched_directly') ?? '0',
      'eventsForcedReload': await readMetadata('events_forced_reload') ?? '0',
      'chatListEventReloads':
          await readMetadata('chat_list_event_reloads') ?? '0',
      'droppedMissingChatGuid':
          await readMetadata('dropped_missing_chat_guid') ?? '0',
      'droppedMalformedEvents':
          await readMetadata('dropped_malformed_events') ?? '0',
      'realtimeLocalDbWrites':
          await readMetadata('realtime_local_db_writes') ?? '0',
      'reconnectCount': await readMetadata('reconnect_count') ?? '0',
      'lastReconnectReason': await readMetadata('last_reconnect_reason'),
    };
  }

  Future<Database> _ready() async {
    await open();
    return _db!;
  }

  void _batchUpsertMessages(
    Batch batch,
    String chatGuid,
    Iterable<MessageModel> messages,
  ) {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final message in messages) {
      // The local cache is the renderable timeline only. The server already
      // filters debug-only/noise rows from the thread API and the realtime feed,
      // so this is defense-in-depth: a noise row can never enter the normal
      // thread even if one slips through. The raw timeline lives behind the
      // server's Message Inspector API, not in this cache.
      if (message.isDebugOnly) continue;
      final key = message.guid.isNotEmpty
          ? 'guid:${message.guid}'
          : 'temp:${message.tempId}';
      if (key.endsWith('null')) continue;
      batch.insert('messages', {
        'key': key,
        'guid': message.guid,
        'temp_id': message.tempId,
        'chat_guid': message.chatGuid ?? chatGuid,
        'json': jsonEncode(message.toJson(chatGuidFallback: chatGuid)),
        'local_state': message.localState.name,
        'date_created': message.dateCreated,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  ChatSummary _chatFromRow(Map<String, Object?> row) {
    final raw = jsonDecode(row['json'] as String) as Map<String, dynamic>;
    final pinned = (row['pinned'] as int? ?? 0) != 0;
    final alwaysVisible = (row['always_visible'] as int? ?? 0) != 0;
    final latestAt = (row['latest_renderable_at'] as int?) ?? 0;
    final lastSeenAt = (row['last_seen_at'] as int?) ?? 0;
    final latestFromMe = (row['latest_from_me'] as int? ?? 0) != 0;
    // C43: the unread dot is derived here from the data — the chat's latest
    // renderable message is newer than this client last saw, and not from me.
    final hasUnread = latestAt > lastSeenAt && !latestFromMe;
    // pinned/hasUnread/latestFromMe live in columns (survive server upserts);
    // fold them into the model.
    final merged = {
      ...raw,
      'isPinned': pinned,
      'hasUnread': hasUnread,
      'latestRenderableFromMe': latestFromMe,
      if (alwaysVisible && raw['hasRenderableMessages'] != true)
        'hasRenderableMessages': true,
    };
    return ChatSummary.fromJson(merged);
  }

  bool _isHiddenRow(List<Map<String, Object?>> rows, String guid) {
    final row = rows.cast<Map<String, Object?>?>().firstWhere(
      (r) => r?['guid'] == guid,
      orElse: () => null,
    );
    if (row == null) return false;
    final alwaysVisible = (row['always_visible'] as int? ?? 0) != 0;
    if (alwaysVisible) return false;
    return (row['hidden'] as int? ?? 0) != 0;
  }

  MessageModel _messageFromRow(Map<String, Object?> row) {
    final raw = jsonDecode(row['json'] as String) as Map<String, dynamic>;
    return MessageModel.fromJson(raw).copyWith(
      localState: LocalSendState.values.firstWhere(
        (s) => s.name == row['local_state'],
        orElse: () => LocalSendState.confirmed,
      ),
    );
  }

  String _previewForMessage(MessageModel message) {
    return messagePreviewText(message);
  }

  bool _isReactionAdd(MessageModel message) {
    final t = message.associatedMessageType;
    if (t == null) return true;
    return t < 3000;
  }

  String _reactionType(MessageModel message) {
    final t = message.associatedMessageType ?? 2000;
    final normalized = t >= 3000 ? t - 1000 : t;
    return switch (normalized) {
      2000 => 'love',
      2001 => 'like',
      2002 => 'dislike',
      2003 => 'laugh',
      2004 => 'emphasis',
      2005 => 'question',
      _ => 'custom',
    };
  }
}

class HiddenMessageRecord {
  final String guid;
  final MessageModel? message;
  final ChatSummary? chat;

  const HiddenMessageRecord({
    required this.guid,
    required this.message,
    required this.chat,
  });
}
