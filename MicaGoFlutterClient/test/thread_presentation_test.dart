import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/features/chats/message_display.dart';
import 'package:mica_go/features/chats/message_render.dart';
import 'package:mica_go/features/chats/models/message_model.dart';
import 'package:mica_go/features/chats/store/thread_presentation.dart';

const _day = 24 * 60 * 60 * 1000;

MessageModel _m({
  required String guid,
  String? text,
  String? subject,
  bool isFromMe = false,
  String? handleId,
  int? dateCreated,
  int? associatedMessageType,
  String? associatedMessageGuid,
  String? threadOriginatorGuid,
  String? expressiveSendStyleId,
  bool isRetracted = false,
  bool isEdited = false,
  bool isRead = false,
  bool isDelivered = false,
  int? dateRead,
  int? dateDelivered,
  int? dateEdited,
  bool cacheHasAttachments = false,
  List<AttachmentModel> attachments = const [],
  String? semanticKind,
  String? renderRecommendation,
  String? unsupportedReason,
  int itemType = 0,
  String? balloonBundleId,
  bool payloadDataPresent = false,
}) => MessageModel(
  guid: guid,
  text: text,
  subject: subject,
  isFromMe: isFromMe,
  handleId: handleId,
  dateCreated: dateCreated,
  associatedMessageType: associatedMessageType,
  associatedMessageGuid: associatedMessageGuid,
  threadOriginatorGuid: threadOriginatorGuid,
  expressiveSendStyleId: expressiveSendStyleId,
  isRetracted: isRetracted,
  isEdited: isEdited,
  isRead: isRead,
  isDelivered: isDelivered,
  dateRead: dateRead,
  dateDelivered: dateDelivered,
  dateEdited: dateEdited,
  cacheHasAttachments: cacheHasAttachments,
  attachments: attachments,
  semanticKind: semanticKind,
  renderRecommendation: renderRecommendation,
  unsupportedReason: unsupportedReason,
  itemType: itemType,
  balloonBundleId: balloonBundleId,
  payloadDataPresent: payloadDataPresent,
  localState: LocalSendState.confirmed,
);

List<ThreadViewItem> _build(
  List<MessageModel> msgs, {
  MessageDisplayPrefs prefs = const MessageDisplayPrefs(),
  bool isGroup = false,
  ContactNameResolver? resolve,
  bool loadingOlder = false,
}) => ThreadPresentationBuilder.build(
  messages: msgs,
  prefs: prefs,
  isGroup: isGroup,
  resolveName: resolve ?? (_) => null,
  loadingOlder: loadingOlder,
);

void main() {
  test('inserts a date separator before each new day', () {
    final t0 = DateTime(2024, 1, 1, 10).millisecondsSinceEpoch;
    final items = _build([
      _m(guid: 'a', text: 'day1', dateCreated: t0),
      _m(guid: 'b', text: 'day1b', dateCreated: t0 + 60000),
      _m(guid: 'c', text: 'day2', dateCreated: t0 + 2 * _day),
    ]);
    final separators = items.whereType<DateSeparatorItem>().length;
    expect(separators, 2); // two distinct days
    expect(items.first, isA<DateSeparatorItem>());
  });

  test('associated sticker is merged onto target, not rendered as a row', () {
    final items = _build([
      _m(guid: 'target', text: 'base', dateCreated: 1000),
      _m(
        guid: 'sticker-row',
        associatedMessageType: 1000,
        associatedMessageGuid: 'p:0/target',
        dateCreated: 1100,
        attachments: const [
          AttachmentModel(
            guid: 'sticker-attachment',
            downloadUrl: '/api/attachments/sticker-attachment',
            isSticker: true,
            attachmentKind: 'sticker',
            displayKind: 'sticker',
          ),
        ],
      ),
    ]);

    final msgs = items.whereType<MessageViewItem>().toList();
    expect(msgs.length, 1);
    expect(msgs.single.message.guid, 'target');
    expect(msgs.single.stickers.single.guid, 'sticker-row');
  });

  test('kept-audio notice rows are hidden like BlueBubbles', () {
    final items = _build([
      _m(
        guid: 'voice',
        dateCreated: 1000,
        attachments: const [
          AttachmentModel(
            guid: 'voice-file',
            downloadUrl: '/api/attachments/voice-file',
            attachmentKind: 'audio',
            isVoiceMessage: true,
            displayKind: 'voice',
          ),
        ],
      ),
      _m(
        guid: 'kept',
        subject: 'Audio Message',
        itemType: 5,
        dateCreated: 1100,
      ),
    ]);

    final msgs = items.whereType<MessageViewItem>().toList();
    expect(msgs.length, 1);
    expect(msgs.single.message.guid, 'voice');
  });

  test('interactive update rows are hidden behind the source app balloon', () {
    const pollsBundle =
        'com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.messages.Polls';
    final items = _build([
      _m(
        guid: 'poll-source',
        text: '�',
        dateCreated: 1000,
        balloonBundleId: pollsBundle,
        payloadDataPresent: true,
      ),
      _m(
        guid: 'poll-update',
        text: ' ',
        dateCreated: 1100,
        associatedMessageType: 4000,
        associatedMessageGuid: 'poll-source',
        balloonBundleId: pollsBundle,
        payloadDataPresent: true,
      ),
    ]);

    final rows = items.whereType<MessageViewItem>().toList();
    expect(rows.length, 1);
    expect(rows.single.message.guid, 'poll-source');
    expect(rows.single.kind, MessageRenderableKind.normal);
  });

  test('precomputes body + sender label (group, incoming) via resolver', () {
    final items = _build(
      [_m(guid: 'a', text: 'hi', handleId: '+15550001', dateCreated: 1000)],
      isGroup: true,
      resolve: (h) => h == '+15550001' ? 'Alice' : null,
    );
    final msg = items.whereType<MessageViewItem>().single;
    expect(msg.body, 'hi');
    expect(msg.senderLabel, 'Alice');
    expect(msg.isSystem, isFalse);
  });

  test('outgoing / 1:1 rows have no sender label', () {
    final items = _build([
      _m(guid: 'a', text: 'hi', isFromMe: true, dateCreated: 1000),
    ]);
    expect(items.whereType<MessageViewItem>().single.senderLabel, isNull);
  });

  test('group sender runs show name first and avatar last', () {
    final t0 = DateTime(2024, 1, 1, 10).millisecondsSinceEpoch;
    final items = _build(
      [
        _m(guid: 'a1', text: 'one', handleId: '+a', dateCreated: t0),
        _m(
          guid: 'a2',
          text: 'two',
          handleId: '+a',
          dateCreated: t0 + 60 * 1000,
        ),
        _m(
          guid: 'a3',
          text: 'three',
          handleId: '+a',
          dateCreated: t0 + 2 * 60 * 1000,
        ),
        _m(
          guid: 'b1',
          text: 'four',
          handleId: '+b',
          dateCreated: t0 + 3 * 60 * 1000,
        ),
        _m(
          guid: 'b2',
          text: 'five',
          handleId: '+b',
          dateCreated: t0 + 9 * 60 * 1000,
        ),
        _m(
          guid: 'me',
          text: 'mine',
          isFromMe: true,
          dateCreated: t0 + 10 * 60 * 1000,
        ),
      ],
      isGroup: true,
      resolve: (h) => switch (h) {
        '+a' => 'JJ',
        '+b' => 'Uex',
        _ => null,
      },
    );

    final msgs = items.whereType<MessageViewItem>().toList();

    expect(msgs.firstWhere((m) => m.message.guid == 'a1').senderLabel, 'JJ');
    expect(
      msgs.firstWhere((m) => m.message.guid == 'a1').showSenderName,
      isTrue,
    );
    expect(
      msgs.firstWhere((m) => m.message.guid == 'a1').showSenderAvatar,
      isFalse,
    );
    expect(
      msgs.firstWhere((m) => m.message.guid == 'a2').showSenderName,
      isFalse,
    );
    expect(
      msgs.firstWhere((m) => m.message.guid == 'a2').showSenderAvatar,
      isFalse,
    );
    expect(
      msgs.firstWhere((m) => m.message.guid == 'a3').showSenderName,
      isFalse,
    );
    expect(
      msgs.firstWhere((m) => m.message.guid == 'a3').showSenderAvatar,
      isTrue,
    );

    expect(
      msgs.firstWhere((m) => m.message.guid == 'b1').showSenderName,
      isTrue,
    );
    expect(
      msgs.firstWhere((m) => m.message.guid == 'b1').showSenderAvatar,
      isTrue,
    );
    expect(
      msgs.firstWhere((m) => m.message.guid == 'b2').showSenderName,
      isTrue,
    );
    expect(
      msgs.firstWhere((m) => m.message.guid == 'b2').showSenderAvatar,
      isTrue,
    );

    final mine = msgs.firstWhere((m) => m.message.guid == 'me');
    expect(mine.senderLabel, isNull);
    expect(mine.showSenderName, isFalse);
    expect(mine.showSenderAvatar, isFalse);
  });

  test('same-side bubble runs get compact vertical spacing flags', () {
    final t0 = DateTime(2024, 1, 1, 10).millisecondsSinceEpoch;
    final items = _build([
      _m(guid: 'me1', text: 'one', isFromMe: true, dateCreated: t0),
      _m(guid: 'me2', text: 'two', isFromMe: true, dateCreated: t0 + 30 * 1000),
      _m(
        guid: 'them1',
        text: 'three',
        handleId: '+a',
        dateCreated: t0 + 60 * 1000,
      ),
      _m(
        guid: 'them2',
        text: 'four',
        handleId: '+a',
        dateCreated: t0 + 90 * 1000,
      ),
      _m(
        guid: 'them3',
        text: 'five',
        handleId: '+b',
        dateCreated: t0 + 120 * 1000,
      ),
    ], isGroup: true);

    final msgs = items.whereType<MessageViewItem>().toList();
    final me1 = msgs.firstWhere((m) => m.message.guid == 'me1');
    final me2 = msgs.firstWhere((m) => m.message.guid == 'me2');
    final them1 = msgs.firstWhere((m) => m.message.guid == 'them1');
    final them2 = msgs.firstWhere((m) => m.message.guid == 'them2');
    final them3 = msgs.firstWhere((m) => m.message.guid == 'them3');

    expect(me1.compactWithPrevious, isFalse);
    expect(me1.compactWithNext, isTrue);
    expect(me2.compactWithPrevious, isTrue);
    expect(me2.compactWithNext, isFalse);
    expect(them1.compactWithNext, isTrue);
    expect(them2.compactWithPrevious, isTrue);
    expect(them2.compactWithNext, isFalse);
    expect(them3.compactWithPrevious, isFalse);
  });

  test('large time gaps break compact bubble runs', () {
    final t0 = DateTime(2024, 1, 1, 10).millisecondsSinceEpoch;
    final items = _build([
      _m(guid: 'a', text: 'one', isFromMe: true, dateCreated: t0),
      _m(
        guid: 'b',
        text: 'two',
        isFromMe: true,
        dateCreated: t0 + 6 * 60 * 1000,
      ),
    ]);

    final msgs = items.whereType<MessageViewItem>().toList();
    expect(msgs[0].compactWithNext, isFalse);
    expect(msgs[1].compactWithPrevious, isFalse);
  });

  test('the previous bubble gets a tail whenever a sender run breaks', () {
    final t0 = DateTime(2024, 1, 1, 10).millisecondsSinceEpoch;
    final items = _build([
      _m(guid: 'same1', text: 'one', handleId: '+a', dateCreated: t0),
      _m(
        guid: 'same2',
        text: 'two',
        handleId: '+a',
        dateCreated: t0 + 30 * 1000,
      ),
      _m(
        guid: 'new-sender',
        text: 'three',
        handleId: '+b',
        dateCreated: t0 + 60 * 1000,
      ),
      _m(
        guid: 'after-gap',
        text: 'four',
        handleId: '+b',
        dateCreated: t0 + 7 * 60 * 1000,
      ),
    ], isGroup: true);

    final messages = items.whereType<MessageViewItem>().toList();
    expect(
      messages.firstWhere((m) => m.message.guid == 'same1').showBubbleTail,
      isFalse,
    );
    expect(
      messages.firstWhere((m) => m.message.guid == 'same2').showBubbleTail,
      isTrue,
    );
    expect(
      messages.firstWhere((m) => m.message.guid == 'new-sender').showBubbleTail,
      isTrue,
    );
    expect(
      messages.firstWhere((m) => m.message.guid == 'after-gap').showBubbleTail,
      isTrue,
    );
  });

  test('reply preview resolved from loaded target', () {
    final items = _build(
      [
        _m(guid: 'target', text: 'original', handleId: '+1', dateCreated: 1000),
        _m(
          guid: 'reply',
          text: 'replying',
          threadOriginatorGuid: 'target',
          dateCreated: 2000,
        ),
      ],
      isGroup: true,
      resolve: (_) => 'Bob',
    );
    final reply = items.whereType<MessageViewItem>().firstWhere(
      (i) => i.message.guid == 'reply',
    );
    expect(reply.reply, isNotNull);
    expect(reply.reply!.targetLoaded, isTrue);
    expect(reply.reply!.text, 'original');
  });

  test('reaction merged into target as a precomputed system-free row', () {
    final items = _build([
      _m(guid: 'target', text: 'nice', dateCreated: 1000),
      _m(
        guid: 'r',
        associatedMessageType: 2000,
        associatedMessageGuid: 'p:0/target',
        dateCreated: 1100,
      ),
    ], prefs: const MessageDisplayPrefs(mergeTapbacks: true));
    final msgs = items.whereType<MessageViewItem>().toList();
    expect(msgs.length, 1); // reaction merged, not a separate row
    expect(msgs.single.reactions.length, 1);
  });

  test('retracted + service rows are system with precomputed labels', () {
    final items = _build([
      _m(guid: 's', itemType: 2, dateCreated: 1000),
      _m(
        guid: 'r',
        text: 'gone',
        isRetracted: true,
        isFromMe: true,
        dateCreated: 2000,
      ),
    ], prefs: const MessageDisplayPrefs(mergeConsecutiveSystem: false));
    final msgs = items.whereType<MessageViewItem>().toList();
    expect(msgs.every((m) => m.isSystem), isTrue);
    final retracted = msgs.firstWhere((m) => m.message.guid == 'r');
    expect(retracted.systemLabel, 'You unsent a message');
  });

  test('empty edited residue is an unsent system row, not a normal bubble', () {
    final items = _build([
      _m(
        guid: 'edited-residue',
        isEdited: true,
        semanticKind: 'empty_edited_residue',
        renderRecommendation: 'system',
        unsupportedReason: 'empty_edited_residue',
        dateCreated: 1000,
      ),
    ], prefs: const MessageDisplayPrefs(mergeConsecutiveSystem: false));
    final row = items.whereType<MessageViewItem>().single;
    // C26: routed to the retracted/unsent presentation, never a broken card.
    expect(row.kind.name, 'retracted');
    expect(row.isSystem, isTrue);
    expect(row.body, isNull);
    expect(row.systemLabel, 'This message was unsent');
  });

  test('effect hint precomputed only when prefs enable it', () {
    final on = _build([
      _m(
        guid: 'a',
        text: 'boom',
        expressiveSendStyleId: 'com.apple.MobileSMS.expressivesend.impact',
        dateCreated: 1,
      ),
    ], prefs: const MessageDisplayPrefs(showEffectHints: true));
    final enabled = on.whereType<MessageViewItem>().single;
    expect(enabled.effectHint, 'Sent with Slam');
    expect(enabled.sendEffect, MessageSendEffect.slam);

    final off = _build([
      _m(
        guid: 'a',
        text: 'boom',
        expressiveSendStyleId: 'com.apple.MobileSMS.expressivesend.impact',
        dateCreated: 1,
      ),
    ], prefs: const MessageDisplayPrefs(showEffectHints: false));
    final disabled = off.whereType<MessageViewItem>().single;
    expect(disabled.effectHint, isNull);
    expect(disabled.sendEffect, MessageSendEffect.slam);
  });

  test(
    'compact delivery visibility shows separate read and delivered markers',
    () {
      final items = _build(
        [
          _m(
            guid: 'read',
            text: 'one',
            isFromMe: true,
            isRead: true,
            dateRead: 1500,
            dateCreated: 1000,
          ),
          _m(
            guid: 'delivered',
            text: 'two',
            isFromMe: true,
            isDelivered: true,
            dateDelivered: 2500,
            dateCreated: 2000,
          ),
          _m(guid: 'latest', text: 'three', isFromMe: true, dateCreated: 3000),
        ],
        prefs: const MessageDisplayPrefs(
          deliveryLabels: DeliveryLabelMode.compact,
        ),
      );
      final msgs = items.whereType<MessageViewItem>().toList();
      expect(
        msgs.firstWhere((m) => m.message.guid == 'read').showStatus,
        isTrue,
      );
      expect(
        msgs.firstWhere((m) => m.message.guid == 'delivered').showStatus,
        isTrue,
      );
      expect(
        msgs.firstWhere((m) => m.message.guid == 'latest').showStatus,
        isTrue,
      );
    },
  );

  test('compact delivery hides stale delivered marker behind newer read', () {
    final items = _build(
      [
        _m(
          guid: 'delivered',
          text: 'one',
          isFromMe: true,
          isDelivered: true,
          dateDelivered: 1500,
          dateCreated: 1000,
        ),
        _m(
          guid: 'read',
          text: 'two',
          isFromMe: true,
          isRead: true,
          dateRead: 2500,
          dateCreated: 2000,
        ),
      ],
      prefs: const MessageDisplayPrefs(
        deliveryLabels: DeliveryLabelMode.compact,
      ),
    );
    final msgs = items.whereType<MessageViewItem>().toList();
    expect(
      msgs.firstWhere((m) => m.message.guid == 'delivered').showStatus,
      isFalse,
    );
    expect(msgs.firstWhere((m) => m.message.guid == 'read').showStatus, isTrue);
  });

  group('C21u timestamp grouping', () {
    test('no time separator for closely-spaced same-day messages', () {
      final t0 = DateTime(2024, 1, 1, 10).millisecondsSinceEpoch;
      final items = _build([
        _m(guid: 'a', text: 'one', dateCreated: t0),
        _m(guid: 'b', text: 'two', dateCreated: t0 + 5 * 60 * 1000), // +5 min
      ]);
      expect(items.whereType<TimeSeparatorItem>(), isEmpty);
      // Exactly one date separator (the day), no extra time chips.
      expect(items.whereType<DateSeparatorItem>().length, 1);
    });

    test('large same-day gaps use the full thread timestamp label', () {
      final t0 = DateTime(2024, 1, 1, 10).millisecondsSinceEpoch;
      final items = _build([
        _m(guid: 'a', text: 'one', dateCreated: t0),
        _m(guid: 'b', text: 'two', dateCreated: t0 + 90 * 60 * 1000), // +90 min
      ]);
      final separators = items.whereType<TimeSeparatorItem>().toList();
      expect(separators.length, 1);
      expect(separators.single.label, contains('2024'));
    });

    test(
      'only the newest outgoing message shows a default footer timestamp',
      () {
        final t0 = DateTime(2024, 1, 1, 10).millisecondsSinceEpoch;
        final items = _build([
          _m(guid: 'a', text: 'one', isFromMe: true, dateCreated: t0),
          _m(
            guid: 'b',
            text: 'two',
            isFromMe: true,
            dateCreated: t0 + 60 * 1000,
          ),
          _m(guid: 'incoming', text: 'three', dateCreated: t0 + 120 * 1000),
        ]);
        final msgs = items.whereType<MessageViewItem>().toList();
        expect(
          msgs.firstWhere((m) => m.message.guid == 'a').showTimestamp,
          isFalse,
        );
        expect(
          msgs.firstWhere((m) => m.message.guid == 'b').showTimestamp,
          isTrue,
        );
        expect(
          msgs.firstWhere((m) => m.message.guid == 'incoming').showTimestamp,
          isFalse,
        );
      },
    );

    test('shouldShowTimeSeparator is pure and correct', () {
      expect(shouldShowTimeSeparator(null, 100), isFalse);
      expect(shouldShowTimeSeparator(0, 30 * 60 * 1000), isFalse); // 30 min
      expect(shouldShowTimeSeparator(0, 60 * 60 * 1000), isTrue); // 60 min
    });
  });

  test('loadingOlder appends a spinner item at the chronological end', () {
    final items = _build([
      _m(guid: 'a', text: 'hi', dateCreated: 1),
    ], loadingOlder: true);
    expect(items.last, isA<LoadingOlderItem>());
  });

  test('stable keys per item', () {
    final items = _build([_m(guid: 'a', text: 'hi', dateCreated: 1)]);
    final keys = items.map((i) => i.key).toList();
    expect(keys.toSet().length, keys.length); // unique
    expect(keys.contains('msg:a'), isTrue);
  });
}
