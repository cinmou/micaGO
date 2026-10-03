import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/features/chats/message_display.dart';
import 'package:mica_go/features/chats/message_render.dart';
import 'package:mica_go/features/chats/store/message_collection.dart';
import 'package:mica_go/features/chats/models/message_model.dart';

MessageModel _server({
  required String guid,
  String? text,
  bool isFromMe = false,
  int? dateCreated,
  int? dateDelivered,
  int? dateRead,
  bool isDelivered = false,
  bool isRead = false,
}) => MessageModel(
  guid: guid,
  text: text,
  isFromMe: isFromMe,
  dateCreated: dateCreated,
  dateDelivered: dateDelivered,
  dateRead: dateRead,
  isDelivered: isDelivered,
  isRead: isRead,
  localState: LocalSendState.confirmed,
);

MessageModel _optimistic(String tempId, String text, int at) =>
    MessageModel.optimistic(tempId: tempId, text: text, dateCreated: at);

void main() {
  test('merged routes keep identical GUIDs, updates and unsends distinct', () {
    final c = MessageCollection();
    final a = _server(
      guid: 'same',
      text: 'A',
      dateCreated: 100,
    ).copyWith(chatGuid: 'a');
    final b = _server(
      guid: 'same',
      text: 'B',
      dateCreated: 200,
    ).copyWith(chatGuid: 'b');
    c.mergeServerPage([a, b]);
    expect(c.ordered.map((m) => m.text), ['A', 'B']);
    expect(c.serverByGuid('same'), isNull);
    c.applyUpdate(b.copyWith(text: 'updated B'));
    expect(c.serverByGuid('same', chatGuid: 'a')!.text, 'A');
    expect(c.applyUnsend('same', 300, chatGuid: 'b'), isTrue);
    expect(c.serverByGuid('same', chatGuid: 'a')!.isRetracted, isFalse);
    c.removeServerMessages(['a\u001fsame']);
    expect(c.ordered.single.chatGuid, 'b');
  });

  group('server message events', () {
    test('message:new inserts and orders by date', () {
      final c = MessageCollection();
      c.upsertServer(_server(guid: 'b', text: 'two', dateCreated: 200));
      c.upsertServer(_server(guid: 'a', text: 'one', dateCreated: 100));
      expect(c.ordered.map((m) => m.guid).toList(), ['a', 'b']);
    });

    test('message:new dedupes by guid (no duplicate bubble)', () {
      final c = MessageCollection();
      c.upsertServer(_server(guid: 'a', text: 'hi', dateCreated: 100));
      c.upsertServer(_server(guid: 'a', text: 'hi', dateCreated: 100));
      expect(c.length, 1);
    });

    test('message:update patches delivered/read by guid in place', () {
      final c = MessageCollection();
      c.upsertServer(
        _server(guid: 'a', text: 'hi', isFromMe: true, dateCreated: 100),
      );
      c.applyUpdate(
        _server(
          guid: 'a',
          text: 'hi',
          isFromMe: true,
          dateCreated: 100,
          isDelivered: true,
          dateDelivered: 150,
        ),
      );
      expect(c.length, 1);
      expect(c.serverByGuid('a')!.isDelivered, isTrue);
      expect(
        deliveryStateFor(c.serverByGuid('a')!),
        MessageDeliveryState.delivered,
      );
    });

    test('read update after delivered upgrades the same row', () {
      final c = MessageCollection();
      c.upsertServer(
        _server(
          guid: 'a',
          isFromMe: true,
          dateCreated: 100,
          isDelivered: true,
          dateDelivered: 150,
        ),
      );
      c.applyUpdate(
        _server(
          guid: 'a',
          isFromMe: true,
          dateCreated: 100,
          isRead: true,
          dateRead: 200,
        ),
      );
      expect(c.length, 1);
      expect(deliveryStateFor(c.serverByGuid('a')!), MessageDeliveryState.read);
    });

    test('message:unsend retracts content; unknown guid returns false', () {
      final c = MessageCollection();
      c.upsertServer(_server(guid: 'a', text: 'secret', dateCreated: 100));
      expect(c.applyUnsend('a', 300), isTrue);
      final m = c.serverByGuid('a')!;
      expect(m.isRetracted, isTrue);
      expect((m.text ?? '').isEmpty, isTrue);
      expect(m.attachments, isEmpty);
      expect(c.applyUnsend('missing', 300), isFalse);
    });

    test('raw reaction events render immediately on their target', () {
      final c = MessageCollection();
      c.upsertServer(_server(guid: 'target', text: 'hi', dateCreated: 100));
      c.upsertServer(
        const MessageModel(
          guid: 'reaction',
          isFromMe: false,
          dateCreated: 200,
          associatedMessageGuid: 'p:0/target',
          associatedMessageType: 2006,
          associatedMessageEmoji: '🥳',
          handleId: 'alice',
        ),
      );
      final rows = buildDisplayRows(c.ordered, const MessageDisplayPrefs());
      expect(rows, hasLength(1));
      expect(activeReactionEmojis(rows.single.reactions), ['🥳']);
      c.upsertServer(
        const MessageModel(
          guid: 'removal',
          isFromMe: false,
          dateCreated: 300,
          associatedMessageGuid: 'p:0/target',
          associatedMessageType: 3006,
          associatedMessageEmoji: '🥳',
          handleId: 'alice',
        ),
      );
      final updated = buildDisplayRows(c.ordered, const MessageDisplayPrefs());
      expect(updated, hasLength(1));
      expect(activeReactionEmojis(updated.single.reactions), isEmpty);
    });
  });

  group('optimistic send lifecycle + reconciliation', () {
    test('pending → sentUnconfirmed → later server row replaces it', () {
      final c = MessageCollection();
      c.addPending(_optimistic('t1', 'hello world', 1000));
      expect(c.pendingByTempId('t1')!.localState, LocalSendState.sending);
      c.setPendingState('t1', LocalSendState.sentUnconfirmed);
      expect(
        c.pendingByTempId('t1')!.localState,
        LocalSendState.sentUnconfirmed,
      );

      // Later outgoing server row with matching text/time.
      c.upsertServer(
        _server(
          guid: 'srv',
          text: 'hello world',
          isFromMe: true,
          dateCreated: 1500,
        ),
      );
      expect(c.pendingByTempId('t1'), isNull); // reconciled away
      expect(c.length, 1); // no duplicate
      expect(c.serverByGuid('srv'), isNotNull);
    });

    test('delivered update after timeout upgrades the reconciled row', () {
      final c = MessageCollection();
      c.addPending(_optimistic('t1', 'yo', 1000));
      c.setPendingState('t1', LocalSendState.sentUnconfirmed);
      c.upsertServer(
        _server(guid: 'srv', text: 'yo', isFromMe: true, dateCreated: 1200),
      );
      c.applyUpdate(
        _server(
          guid: 'srv',
          text: 'yo',
          isFromMe: true,
          dateCreated: 1200,
          isDelivered: true,
          dateDelivered: 1300,
        ),
      );
      expect(c.length, 1);
      expect(
        deliveryStateFor(c.serverByGuid('srv')!),
        MessageDeliveryState.delivered,
      );
    });

    test('confirmPending replaces temp with server, no dup', () {
      final c = MessageCollection();
      final pending = _optimistic('t1', 'hi', 1000);
      c.addPending(pending);
      c.confirmPending(
        't1',
        _server(guid: 'srv', text: 'hi', isFromMe: true, dateCreated: 1000),
      );
      expect(c.pendingByTempId('t1'), isNull);
      expect(c.length, 1);
      expect(c.presentationKeyFor(c.serverByGuid('srv')!), pending.dedupeKey);
    });

    test('actual failure stays failed and is retryable', () {
      final c = MessageCollection();
      c.addPending(_optimistic('t1', 'oops', 1000));
      c.setPendingState('t1', LocalSendState.failed);
      expect(c.pendingByTempId('t1')!.localState, LocalSendState.failed);
      // Unrelated server message must NOT reconcile the failed row away.
      c.upsertServer(
        _server(
          guid: 'other',
          text: 'different',
          isFromMe: true,
          dateCreated: 1100,
        ),
      );
      expect(c.pendingByTempId('t1'), isNotNull);
      // Retry removes it and returns the complete row to resend.
      expect(c.removePending('t1')?.text, 'oops');
      expect(c.pendingByTempId('t1'), isNull);
    });

    test('unrelated outgoing message does not match a pending send', () {
      final c = MessageCollection();
      c.addPending(_optimistic('t1', 'apples', 1000));
      c.upsertServer(
        _server(
          guid: 'srv',
          text: 'oranges',
          isFromMe: true,
          dateCreated: 1000,
        ),
      );
      expect(c.pendingByTempId('t1'), isNotNull);
      expect(c.length, 2);
    });

    test('incoming message never reconciles an outgoing pending', () {
      final c = MessageCollection();
      c.addPending(_optimistic('t1', 'hi', 1000));
      c.upsertServer(
        _server(guid: 'in', text: 'hi', isFromMe: false, dateCreated: 1000),
      );
      expect(c.pendingByTempId('t1'), isNotNull);
    });
  });

  group('pages', () {
    test('mergeServerPage keeps pending and reconciles matches', () {
      final c = MessageCollection();
      c.addPending(_optimistic('t1', 'kept', 1000));
      c.addPending(_optimistic('t2', 'matched', 1000));
      c.mergeServerPage([
        _server(guid: 's1', text: 'matched', isFromMe: true, dateCreated: 1000),
      ]);
      expect(c.pendingByTempId('t2'), isNull); // reconciled
      expect(c.pendingByTempId('t1'), isNotNull); // kept
    });

    // C78: a page in flight must not wipe messages delivered while it loaded —
    // the merged view multiplies that window by the number of routes.
    test('mergeServerPage keeps rows that arrived during the fetch', () {
      final c = MessageCollection();
      c.upsertServer(_server(guid: 'old', dateCreated: 1000));
      c.upsertServer(_server(guid: 'live', dateCreated: 3000));
      // The page was taken before 'live' existed.
      c.mergeServerPage([_server(guid: 'old', dateCreated: 1000)]);
      expect(c.ordered.map((m) => m.guid).toList(), ['old', 'live']);
    });

    test('mergeServerPage preserves older loaded history', () {
      final c = MessageCollection();
      c.upsertServer(_server(guid: 'gone', dateCreated: 1000));
      c.upsertServer(_server(guid: 'kept', dateCreated: 2000));
      c.mergeServerPage([_server(guid: 'kept', dateCreated: 2000)]);
      expect(c.ordered.map((m) => m.guid).toList(), ['gone', 'kept']);
    });

    test('stale page cannot overwrite a realtime edit', () {
      final c = MessageCollection();
      final old = _server(guid: 'a', text: 'before', dateCreated: 1000);
      c.upsertServer(old);
      final baseline = c.snapshot();
      c.upsertServer(_server(guid: 'a', text: 'after', dateCreated: 1000));
      c.mergeServerPage([old], baseline: baseline);
      expect(c.ordered.single.text, 'after');
    });

    test('explicit removal survives an in-flight page', () {
      final c = MessageCollection();
      final row = _server(guid: 'a', dateCreated: 1000);
      c.upsertServer(row);
      final baseline = c.snapshot();
      c.removeServerMessages(['a']);
      c.mergeServerPage([row], baseline: baseline);
      expect(c.ordered, isEmpty);
    });

    test('an empty page never clears the thread', () {
      final c = MessageCollection();
      c.upsertServer(_server(guid: 'a', dateCreated: 1000));
      c.mergeServerPage(const []);
      expect(c.ordered.map((m) => m.guid).toList(), ['a']);
    });

    test('mergeOlder does not drop newer messages', () {
      final c = MessageCollection();
      c.upsertServer(_server(guid: 'new', dateCreated: 200));
      c.mergeOlder([_server(guid: 'old', dateCreated: 100)]);
      expect(c.ordered.map((m) => m.guid).toList(), ['old', 'new']);
    });
  });
}
