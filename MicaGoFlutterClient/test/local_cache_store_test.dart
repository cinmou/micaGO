import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/storage/local_cache_store.dart';
import 'package:mica_go/features/chats/models/chat_summary.dart';
import 'package:mica_go/features/chats/models/message_model.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late LocalCacheStore store;

  setUp(() async {
    store = LocalCacheStore();
    await store.open();
    await store.clearAll();
  });

  tearDown(() async {
    await store.clearAll();
    await store.close();
  });

  test('cold start returns cached chats and messages', () async {
    await store.upsertChats([
      const ChatSummary(
        guid: 'chat-1',
        chatIdentifier: '+15550001',
        lastMessageAt: 20,
        lastMessagePreview: 'hello',
      ),
    ]);
    await store.replaceServerPage('chat-1', [
      MessageModel.fromJson({
        'guid': 'm1',
        'chatGuid': 'chat-1',
        'text': 'hello',
        'dateCreated': 20,
      }),
    ]);

    final chats = await store.listChats();
    final messages = await store.listMessages('chat-1');

    expect(chats.single.guid, 'chat-1');
    expect(messages.single.text, 'hello');
  });

  test('drops cached opaque URL preview payload attachments', () async {
    await store.replaceServerPage('chat-1', [
      MessageModel.fromJson({
        'guid': 'm1',
        'chatGuid': 'chat-1',
        'text': 'https://privygallery.cinmou.uk',
        'cacheHasAttachments': true,
        'attachments': [
          {
            'guid': 'payload',
            'filename': '88A910B7-31DB-48EF-8124-136AC0D0B9EF',
            'transferName': '88A910B7-31DB-48EF-8124-136AC0D0B9EF',
            'uti': 'public.data',
            'attachmentKind': 'file',
            'displayKind': 'file',
            'downloadUrl': '/api/attachments/payload',
          },
          {
            'guid': 'doc',
            'transferName': 'report.pdf',
            'attachmentKind': 'file',
            'displayKind': 'file',
            'downloadUrl': '/api/attachments/doc',
          },
        ],
      }),
    ]);

    final messages = await store.listMessages('chat-1');
    expect(messages.single.attachments, hasLength(1));
    expect(messages.single.attachments.single.guid, 'doc');
  });

  test('diagnostics reports local DB path schema and counts', () async {
    await store.upsertChats([
      const ChatSummary(guid: 'chat-1', hasRenderableMessages: true),
    ]);
    await store.replaceServerPage('chat-1', [
      MessageModel.fromJson({
        'guid': 'm1',
        'chatGuid': 'chat-1',
        'text': 'hello',
        'dateCreated': 20,
      }),
    ]);
    await store.writeMetadata('last_bootstrap_time', '123');
    await store.writeMetadata('last_write_count', '2');

    final diag = await store.diagnostics();
    expect(diag['path'], contains('micago_client_cache.db'));
    expect(diag['schemaVersion'], isA<int>());
    expect(diag['chatCount'], 1);
    expect(diag['messageCount'], 1);
    expect(diag['pendingSendCount'], 0);
    expect(diag['lastBootstrapTime'], '123');
    expect(diag['lastWriteCount'], '2');
  });

  test('realtime cursor metadata persists across reopen', () async {
    await store.writeMetadata('last_applied_event_cursor', 'n:42');
    await store.writeMetadata('last_event_at', '1234');
    await store.close();

    store = LocalCacheStore();
    await store.open();
    final diag = await store.diagnostics();
    expect(diag['lastAppliedEventCursor'], 'n:42');
    expect(diag['lastEventAt'], '1234');
  });

  test(
    'message event bumps known chat locally without server reload',
    () async {
      await store.upsertChats([
        const ChatSummary(
          guid: 'chat-1',
          chatIdentifier: '+15550001',
          lastMessageAt: 20,
          lastMessagePreview: 'old',
        ),
      ]);
      final ok = await store.bumpChatWithMessage(
        MessageModel.fromJson({
          'guid': 'm2',
          'chatGuid': 'chat-1',
          'text': 'new',
          'dateCreated': 30,
        }),
      );
      final chats = await store.listChats();
      expect(ok, isTrue);
      expect(chats.single.lastMessagePreview, 'new');
      expect(chats.single.lastMessageAt, 30);
    },
  );

  test('a newer incoming message derives hasUnread (watermark)', () async {
    // Inserted with its current latest (20) as the seen watermark.
    await store.upsertChats([
      const ChatSummary(
        guid: 'chat-1',
        chatIdentifier: '+15550001',
        lastMessageAt: 20,
        lastMessagePreview: 'old',
      ),
    ]);
    expect((await store.listChats()).single.hasUnread, isFalse,
        reason: 'existing history starts seen');

    final ok = await store.bumpChatWithMessage(
      MessageModel.fromJson({
        'guid': 'm2',
        'chatGuid': 'chat-1',
        'text': 'new',
        'isFromMe': false,
        'dateCreated': 30,
      }),
      markUnread: true,
    );

    final chat = (await store.listChats()).single;
    expect(ok, isTrue);
    expect(chat.hasUnread, isTrue, reason: '30 > seen 20 and not from me');
    expect(chat.unreadCount, 1);
  });

  test('my own newer message does not light unread', () async {
    await store.upsertChats([
      const ChatSummary(guid: 'c1', lastMessageAt: 20, lastMessagePreview: 'x'),
    ]);
    await store.bumpChatWithMessage(
      MessageModel.fromJson({
        'guid': 'mine',
        'chatGuid': 'c1',
        'text': 'sent',
        'isFromMe': true,
        'dateCreated': 40,
      }),
      seen: true,
    );
    expect((await store.listChats()).single.hasUnread, isFalse);
  });

  test('markChatsSeen advances the watermark and clears the dot', () async {
    await store.upsertChats([
      const ChatSummary(guid: 'c1', lastMessageAt: 20, lastMessagePreview: 'x'),
    ]);
    await store.bumpChatWithMessage(
      MessageModel.fromJson({
        'guid': 'in',
        'chatGuid': 'c1',
        'text': 'hi',
        'isFromMe': false,
        'dateCreated': 30,
      }),
      markUnread: true,
    );
    expect((await store.listChats()).single.hasUnread, isTrue);

    await store.markChatsSeen(['c1']);
    final chat = (await store.listChats()).single;
    expect(chat.hasUnread, isFalse);
    expect(chat.unreadCount, 0);
  });

  test('a backgrounded message (seen:false) re-lights the dot after open', () async {
    // Open the chat (watermark catches up to its latest), then a new message
    // arrives while backgrounded — bumped with seen:false — must light the dot
    // again even though the chat was "seen" moments ago (C45).
    await store.upsertChats([
      const ChatSummary(guid: 'c1', lastMessageAt: 20, lastMessagePreview: 'x'),
    ]);
    await store.markChatsSeen(['c1']);
    expect((await store.listChats()).single.hasUnread, isFalse);

    await store.bumpChatWithMessage(
      MessageModel.fromJson({
        'guid': 'bg',
        'chatGuid': 'c1',
        'text': 'while backgrounded',
        'isFromMe': false,
        'dateCreated': 99,
      }),
      markUnread: true,
      seen: false,
    );
    expect((await store.listChats()).single.hasUnread, isTrue);
  });

  test('markChatsSeen(upTo:) clears a not-yet-bumped arrival (C47 race)', () async {
    // The open thread observes a WS/delta message and marks itself read, but the
    // chat-list ingestion has not yet bumped latest_renderable_at for it. Passing
    // the message timestamp via upTo must still advance the watermark past it so
    // no stale dot lingers regardless of which write wins the race.
    await store.upsertChats([
      const ChatSummary(guid: 'c1', lastMessageAt: 20, lastMessagePreview: 'x'),
    ]);
    await store.markChatsSeen(['c1']);
    expect((await store.listChats()).single.hasUnread, isFalse);

    // Watermark catches up to the arrival's timestamp before the row is bumped.
    await store.markChatsSeen(['c1'], upTo: 80);
    // Now the (late) ingestion bumps the row to the same message — still seen.
    await store.bumpChatWithMessage(
      MessageModel.fromJson({
        'guid': 'late',
        'chatGuid': 'c1',
        'text': 'arrived while viewing',
        'isFromMe': false,
        'dateCreated': 80,
      }),
      markUnread: true,
      seen: false,
    );
    expect((await store.listChats()).single.hasUnread, isFalse,
        reason: 'upTo advanced the watermark to 80, matching the new message');
  });

  test('markChatsSeen never regresses the watermark', () async {
    await store.upsertChats([
      const ChatSummary(guid: 'c1', lastMessageAt: 90, lastMessagePreview: 'x'),
    ]);
    await store.markChatsSeen(['c1']); // watermark = 90
    // A stale upTo from an older event must not pull the watermark back.
    await store.markChatsSeen(['c1'], upTo: 10);
    await store.bumpChatWithMessage(
      MessageModel.fromJson({
        'guid': 'older',
        'chatGuid': 'c1',
        'text': 'older',
        'isFromMe': false,
        'dateCreated': 50,
      }),
      markUnread: true,
      seen: false,
    );
    expect((await store.listChats()).single.hasUnread, isFalse,
        reason: 'watermark stayed at 90; a 50ms message is already seen');
  });

  test('a server refresh keeps a chat read until a newer message', () async {
    await store.upsertChats([
      const ChatSummary(guid: 'c1', lastMessageAt: 20, lastMessagePreview: 'x'),
    ]);
    await store.markChatsSeen(['c1']);
    // Re-sending the same latest (20) on refresh must not re-light unread.
    await store.upsertChats([
      const ChatSummary(guid: 'c1', lastMessageAt: 20, lastMessagePreview: 'x'),
    ]);
    expect((await store.listChats()).single.hasUnread, isFalse);
    // A genuinely newer incoming message (from the server's latestFromMe=false)
    // does light it.
    await store.upsertChats([
      const ChatSummary(guid: 'c1', lastMessageAt: 50, lastMessagePreview: 'new'),
    ]);
    expect((await store.listChats()).single.hasUnread, isTrue);
  });

  test('removeChats deletes cached chat rows and message history', () async {
    await store.upsertChats([
      const ChatSummary(guid: 'test-chat', lastMessagePreview: 'old'),
    ]);
    await store.replaceServerPage('test-chat', [
      MessageModel.fromJson({
        'guid': 'm1',
        'chatGuid': 'test-chat',
        'text': 'cached',
        'dateCreated': 20,
      }),
    ]);

    await store.removeChats(['test-chat']);

    expect(await store.listChats(includeHidden: true), isEmpty);
    expect(await store.listMessages('test-chat'), isEmpty);
  });

  test('pinned chats sort to the top and survive a server upsert', () async {
    await store.upsertChats([
      const ChatSummary(guid: 'chat-old', lastMessageAt: 10),
      const ChatSummary(guid: 'chat-new', lastMessageAt: 99),
    ]);
    await store.setChatPinned('chat-old', true);

    var chats = await store.listChats();
    expect(chats.first.guid, 'chat-old', reason: 'pinned chat is first');
    expect(chats.first.isPinned, isTrue);

    // A server refresh (no pin field) must not reset the pin.
    await store.upsertChats([
      const ChatSummary(guid: 'chat-old', lastMessageAt: 10),
      const ChatSummary(guid: 'chat-new', lastMessageAt: 99),
    ]);
    chats = await store.listChats();
    expect(chats.first.guid, 'chat-old');
  });

  test('hidden message is filtered from the thread and restorable', () async {
    await store.upsertChats([const ChatSummary(guid: 'c1', lastMessageAt: 1)]);
    await store.replaceServerPage('c1', [
      MessageModel.fromJson({
        'guid': 'a',
        'chatGuid': 'c1',
        'text': 'keep',
        'dateCreated': 1,
      }),
      MessageModel.fromJson({
        'guid': 'b',
        'chatGuid': 'c1',
        'text': 'hide me',
        'dateCreated': 2,
      }),
    ]);

    await store.setMessageHidden('b', true);
    expect((await store.listMessages('c1')).map((m) => m.guid), ['a']);
    expect(await store.hiddenMessageCount(), 1);

    // A re-sync (delete + reinsert) must not resurrect the hidden message.
    await store.replaceServerPage('c1', [
      MessageModel.fromJson({
        'guid': 'a',
        'chatGuid': 'c1',
        'text': 'keep',
        'dateCreated': 1,
      }),
      MessageModel.fromJson({
        'guid': 'b',
        'chatGuid': 'c1',
        'text': 'hide me',
        'dateCreated': 2,
      }),
    ]);
    expect((await store.listMessages('c1')).length, 1);

    expect(await store.releaseAllHiddenMessages(), 1);
    expect((await store.listMessages('c1')).length, 2);
  });

  test('hidden chat count + release restores the contact', () async {
    await store.upsertChats([
      const ChatSummary(guid: 'c1', lastMessageAt: 1, lastMessagePreview: 'x'),
      const ChatSummary(guid: 'c2', lastMessageAt: 2, lastMessagePreview: 'y'),
    ]);
    await store.setChatHidden('c1', true);

    expect(await store.hiddenChatCount(), 1);
    expect((await store.listChats()).map((c) => c.guid), ['c2']);

    expect(await store.releaseAllHiddenChats(), 1);
    expect((await store.listChats()).length, 2);
  });


  test(
    'server chat refresh preserves local unread when server omits it',
    () async {
      await store.upsertChats([
        const ChatSummary(
          guid: 'chat-1',
          lastMessageAt: 20,
          lastMessagePreview: 'old',
          unreadCount: 3,
        ),
      ]);

      await store.upsertChats([
        const ChatSummary(
          guid: 'chat-1',
          lastMessageAt: 40,
          lastMessagePreview: 'server',
        ),
      ]);

      final chat = (await store.listChats()).single;
      expect(chat.lastMessagePreview, 'server');
      expect(chat.unreadCount, 3);
    },
  );

  test('older message event does not move chat preview backward', () async {
    await store.upsertChats([
      const ChatSummary(
        guid: 'chat-1',
        lastMessageAt: 50,
        lastMessagePreview: 'newer',
      ),
    ]);
    final ok = await store.bumpChatWithMessage(
      MessageModel.fromJson({
        'guid': 'old',
        'chatGuid': 'chat-1',
        'text': 'older',
        'dateCreated': 10,
      }),
    );
    final chat = (await store.listChats()).single;
    expect(ok, isTrue);
    expect(chat.lastMessagePreview, 'newer');
    expect(chat.lastMessageAt, 50);
  });

  test('message update and unsend patch existing row', () async {
    await store.upsertMessage(
      'chat-1',
      MessageModel.fromJson({
        'guid': 'm1',
        'chatGuid': 'chat-1',
        'text': 'hello',
        'dateCreated': 20,
      }),
    );
    await store.upsertMessage(
      'chat-1',
      MessageModel.fromJson({
        'guid': 'm1',
        'chatGuid': 'chat-1',
        'text': 'hello',
        'dateCreated': 20,
        'dateDelivered': 30,
        'isDelivered': true,
      }),
    );
    expect((await store.listMessages('chat-1')).single.isDelivered, isTrue);

    await store.applyUnsend('chat-1', 'm1', 40);
    final retracted = (await store.listMessages('chat-1')).single;
    expect(retracted.isRetracted, isTrue);
    expect(retracted.text, '');
  });

  test(
    'reaction event updates target message instead of standalone row',
    () async {
      await store.upsertMessage(
        'chat-1',
        MessageModel.fromJson({
          'guid': 'target',
          'chatGuid': 'chat-1',
          'text': 'hello',
          'dateCreated': 20,
        }),
      );
      final ok = await store.applyReactionEvent(
        'chat-1',
        MessageModel.fromJson({
          'guid': 'reaction-1',
          'chatGuid': 'chat-1',
          'associatedMessageType': 2001,
          'associatedMessageGuid': 'p:target',
          'handle': {'id': '+15550001'},
          'dateCreated': 30,
        }),
      );
      final messages = await store.listMessages('chat-1');
      expect(ok, isTrue);
      expect(messages, hasLength(1));
      expect(messages.single.guid, 'target');
      expect(messages.single.reactions.single.type, 'like');
    },
  );

  test(
    'sentUnconfirmed survives restart and reconciles with send match',
    () async {
      final pending = MessageModel.optimistic(
        tempId: 'tmp-1',
        text: 'slow',
        dateCreated: 100,
      ).copyWith(localState: LocalSendState.sentUnconfirmed);
      await store.addPending('chat-1', pending);
      await store.close();

      store = LocalCacheStore();
      await store.open();
      var messages = await store.listMessages('chat-1');
      expect(messages.single.localState, LocalSendState.sentUnconfirmed);

      await store.confirmPending(
        'chat-1',
        'tmp-1',
        MessageModel.fromJson({
          'guid': 'real-1',
          'chatGuid': 'chat-1',
          'text': 'slow',
          'dateCreated': 101,
          'isFromMe': true,
        }),
      );
      messages = await store.listMessages('chat-1');
      expect(messages.single.guid, 'real-1');
      expect(messages.single.localState, LocalSendState.confirmed);
    },
  );

  test('debug-only/noise rows cannot enter the normal thread cache', () async {
    // C12: the local cache is the renderable timeline only. Even if a debug-only
    // row reaches the client, it must not be stored in (or returned from) the
    // normal thread — the raw timeline lives behind the server Inspector API.
    await store.replaceServerPage('chat-1', [
      MessageModel.fromJson({
        'guid': 'real',
        'chatGuid': 'chat-1',
        'text': 'hello',
        'dateCreated': 20,
      }),
      MessageModel.fromJson({
        'guid': 'noise',
        'chatGuid': 'chat-1',
        'dateCreated': 21,
        'isDebugOnly': true,
      }),
    ]);

    final messages = await store.listMessages('chat-1');
    expect(messages, hasLength(1));
    expect(messages.single.guid, 'real');

    // Direct single-row upsert of a noise row is also rejected.
    await store.upsertMessage(
      'chat-1',
      MessageModel.fromJson({
        'guid': 'noise-2',
        'chatGuid': 'chat-1',
        'dateCreated': 22,
        'isDebugOnly': true,
      }),
    );
    expect((await store.listMessages('chat-1')), hasLength(1));
  });

  test('hidden chat is hidden locally and always visible overrides', () async {
    await store.upsertChats([
      const ChatSummary(guid: 'noise', hasRenderableMessages: false),
    ]);
    expect(await store.listChats(), isEmpty);
    expect(await store.listChats(includeDebug: true), hasLength(1));

    await store.setChatAlwaysVisible('noise', true);
    expect(await store.listChats(), hasLength(1));

    await store.setChatHidden('noise', true);
    expect(await store.listChats(), hasLength(1));
  });

  test('chat flags export + pending-restore round trip (C54)', () async {
    await store.upsertChats([
      const ChatSummary(guid: 'c1', lastMessageAt: 10, lastMessagePreview: 'x'),
      const ChatSummary(guid: 'c2', lastMessageAt: 20, lastMessagePreview: 'y'),
      const ChatSummary(guid: 'plain', lastMessageAt: 5, lastMessagePreview: 'z'),
    ]);
    await store.setChatPinned('c1', true);
    await store.setChatHidden('c2', true);

    final exported = await store.exportChatFlags();
    expect(exported.keys, containsAll(<String>['c1', 'c2']));
    expect(exported.containsKey('plain'), isFalse);
    expect(exported['c1']!['pinned'], 1);
    expect(exported['c2']!['hidden'], 1);

    // Simulate a restore onto a fresh cache: pending flags applied as chats sync.
    await store.clearAll();
    await store.setPendingChatFlags(exported);
    // c1 not synced yet → its flag stays pending; c2 synced → its flag applies.
    await store.upsertChats([
      const ChatSummary(guid: 'c2', lastMessageAt: 20, lastMessagePreview: 'y'),
    ]);
    await store.applyPendingChatFlags();
    // c2 is now hidden: excluded by default, present with includeHidden.
    expect(
      (await store.listChats()).where((c) => c.guid == 'c2'),
      isEmpty,
    );
    expect(
      (await store.listChats(includeHidden: true)).where((c) => c.guid == 'c2'),
      isNotEmpty,
    );

    // c1 syncs later → its pending pin now applies.
    await store.upsertChats([
      const ChatSummary(guid: 'c1', lastMessageAt: 10, lastMessagePreview: 'x'),
    ]);
    await store.applyPendingChatFlags();
    expect(
      (await store.listChats()).firstWhere((c) => c.guid == 'c1').isPinned,
      isTrue,
    );
  });
}
