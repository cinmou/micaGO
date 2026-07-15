import 'package:flutter_test/flutter_test.dart';
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

    test('reaction event updates target instead of adding standalone row', () {
      final c = MessageCollection();
      c.upsertServer(_server(guid: 'target', text: 'hi', dateCreated: 100));
      expect(
        c.applyReactionEvent(
          targetGuid: 'target',
          reaction: const ReactionModel(
            type: 'like',
            fromHandle: '+15550001',
            isFromMe: false,
            eventGuid: 'reaction-1',
          ),
          add: true,
        ),
        isTrue,
      );
      expect(c.length, 1);
      expect(c.serverByGuid('target')!.reactions.single.type, 'like');

      expect(
        c.applyReactionEvent(
          targetGuid: 'target',
          reaction: const ReactionModel(
            type: 'like',
            fromHandle: '+15550001',
            isFromMe: false,
          ),
          add: false,
        ),
        isTrue,
      );
      expect(c.serverByGuid('target')!.reactions, isEmpty);
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
      c.addPending(_optimistic('t1', 'hi', 1000));
      c.confirmPending(
        't1',
        _server(guid: 'srv', text: 'hi', isFromMe: true, dateCreated: 1000),
      );
      expect(c.pendingByTempId('t1'), isNull);
      expect(c.length, 1);
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
    test('replaceServerPage keeps pending and reconciles matches', () {
      final c = MessageCollection();
      c.addPending(_optimistic('t1', 'kept', 1000));
      c.addPending(_optimistic('t2', 'matched', 1000));
      c.replaceServerPage([
        _server(guid: 's1', text: 'matched', isFromMe: true, dateCreated: 1000),
      ]);
      expect(c.pendingByTempId('t2'), isNull); // reconciled
      expect(c.pendingByTempId('t1'), isNotNull); // kept
    });

    test('mergeOlder does not drop newer messages', () {
      final c = MessageCollection();
      c.upsertServer(_server(guid: 'new', dateCreated: 200));
      c.mergeOlder([_server(guid: 'old', dateCreated: 100)]);
      expect(c.ordered.map((m) => m.guid).toList(), ['old', 'new']);
    });
  });
}
