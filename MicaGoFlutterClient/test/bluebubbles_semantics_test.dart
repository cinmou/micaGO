import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/features/chats/message_display.dart';
import 'package:mica_go/features/chats/message_render.dart';
import 'package:mica_go/features/chats/models/message_model.dart';
import 'package:mica_go/features/contacts/contact_identity.dart';

MessageModel _m({
  String guid = 'g',
  String? text,
  bool isFromMe = false,
  String? handleId,
  int? associatedMessageType,
  String? associatedMessageGuid,
  String? threadOriginatorGuid,
  String? expressiveSendStyleId,
  int itemType = 0,
  bool isRetracted = false,
  String? semanticKind,
  List<AttachmentModel> attachments = const [],
  int errorCode = 0,
  LocalSendState localState = LocalSendState.confirmed,
}) {
  return MessageModel(
    guid: guid,
    text: text,
    isFromMe: isFromMe,
    handleId: handleId,
    associatedMessageType: associatedMessageType,
    associatedMessageGuid: associatedMessageGuid,
    threadOriginatorGuid: threadOriginatorGuid,
    expressiveSendStyleId: expressiveSendStyleId,
    itemType: itemType,
    semanticKind: semanticKind,
    attachments: attachments,
    isRetracted: isRetracted,
    errorCode: errorCode,
    localState: localState,
  );
}

void main() {
  group('tapback mapping', () {
    test('codes map to kinds + add/remove', () {
      expect(tapbackFromCode(2000)!.kind, TapbackKind.love);
      expect(tapbackFromCode(2001)!.kind, TapbackKind.like);
      expect(tapbackFromCode(2005)!.kind, TapbackKind.question);
      expect(tapbackFromCode(3000)!.kind, TapbackKind.love);
      expect(tapbackFromCode(3000)!.isRemoval, isTrue);
      expect(tapbackFromCode(2000)!.isRemoval, isFalse);
      expect(tapbackFromCode(0), isNull);
      expect(tapbackFromCode(null), isNull);
    });

    test('emoji lookup', () {
      expect(tapbackEmoji(TapbackKind.like), '\u{1F44D}');
    });

    test('isReaction requires a reaction code + target', () {
      expect(
        isReaction(
          _m(associatedMessageType: 2000, associatedMessageGuid: 'p:0/x'),
        ),
        isTrue,
      );
      expect(isReaction(_m(associatedMessageType: 2000)), isFalse); // no target
      expect(
        isReaction(_m(associatedMessageGuid: 'p:0/x')),
        isFalse,
      ); // no code
      // A sticker (1000) is not a tapback chip.
      expect(
        isReaction(
          _m(associatedMessageType: 1000, associatedMessageGuid: 'p:0/x'),
        ),
        isFalse,
      );
    });

    test('reactionTargetGuid strips p:/bp: prefixes', () {
      expect(reactionTargetGuid('p:0/ABC'), 'ABC');
      expect(reactionTargetGuid('bp:XYZ'), 'XYZ');
      expect(reactionTargetGuid('plain'), 'plain');
      expect(reactionTargetGuid(''), isNull);
    });
  });

  group('replies', () {
    test('isReply detects threadOriginatorGuid', () {
      expect(isReply(_m(threadOriginatorGuid: 'm1')), isTrue);
      expect(isReply(_m()), isFalse);
    });
  });

  group('effects', () {
    test('known + unknown + none', () {
      expect(
        effectLabel('com.apple.MobileSMS.expressivesend.impact'),
        'Sent with Slam',
      );
      expect(
        effectLabel('com.apple.messages.effect.CKHappyBirthdayEffect'),
        'Sent with Balloons',
      );
      expect(effectLabel('com.apple.unknown.effect'), 'Sent with an effect');
      expect(effectLabel(null), isNull);
      expect(effectLabel(''), isNull);
      expect(
        sendEffectFor('com.apple.MobileSMS.expressivesend.impact'),
        MessageSendEffect.slam,
      );
      expect(
        sendEffectFor('com.apple.MobileSMS.expressivesend.loud'),
        MessageSendEffect.loud,
      );
      expect(
        sendEffectFor('com.apple.MobileSMS.expressivesend.gentle'),
        MessageSendEffect.gentle,
      );
      expect(
        sendEffectFor('com.apple.messages.effect.CKConfettiEffect'),
        MessageSendEffect.confetti,
      );
      expect(
        sendEffectFor('com.apple.MobileSMS.expressivesend.invisibleink'),
        MessageSendEffect.invisibleInk,
      );
      expect(
        sendEffectFor('com.apple.messages.effect.CKHappyBirthdayEffect'),
        MessageSendEffect.balloons,
      );
      expect(
        sendEffectFor('com.apple.messages.effect.CKFireworksEffect'),
        MessageSendEffect.fireworks,
      );
      expect(
        sendEffectFor('com.apple.messages.effect.CKHeartEffect'),
        MessageSendEffect.love,
      );
      expect(
        sendEffectFor('com.apple.messages.effect.CKLasersEffect'),
        MessageSendEffect.lasers,
      );
      expect(
        sendEffectFor('com.apple.messages.effect.CKSparklesEffect'),
        MessageSendEffect.celebration,
      );
      expect(
        sendEffectFor('com.apple.messages.effect.CKSpotlightEffect'),
        MessageSendEffect.spotlight,
      );
      expect(
        sendEffectFor('com.apple.messages.effect.CKEchoEffect'),
        MessageSendEffect.echo,
      );
      // Screen vs. bubble classification.
      expect(isScreenSendEffect(MessageSendEffect.fireworks), isTrue);
      expect(isScreenSendEffect(MessageSendEffect.slam), isFalse);
      expect(isScreenSendEffect(MessageSendEffect.invisibleInk), isFalse);
      expect(sendEffectFor('com.apple.unknown.effect'), MessageSendEffect.none);
    });
  });

  group('retracted (unsent)', () {
    test('renderableKind + label', () {
      final m = _m(isRetracted: true, isFromMe: true);
      expect(renderableKindFor(m), MessageRenderableKind.retracted);
      expect(retractedLabel(m), 'You unsent a message');
      expect(retractedLabel(_m(isRetracted: true)), 'This message was unsent');
    });

    test('retracted attachment content renders as system row', () {
      final rows = buildDisplayRows([
        _m(
          guid: 'att',
          isRetracted: true,
          attachments: const [
            AttachmentModel(
              guid: 'a',
              downloadUrl: '/x',
              attachmentKind: 'image',
              isPreviewableImage: true,
            ),
          ],
        ),
      ], const MessageDisplayPrefs());
      expect(rows.single.kind, MessageRenderableKind.retracted);
      expect(rows.single.message.attachments, isNotEmpty);
    });

    test('label uses the sender name for others', () {
      expect(
        retractedLabel(_m(isRetracted: true), senderName: 'Alex'),
        'Alex unsent a message',
      );
      // Own messages always read "You" regardless of any provided name.
      expect(
        retractedLabel(_m(isRetracted: true, isFromMe: true), senderName: 'X'),
        'You unsent a message',
      );
    });
  });

  // C26: unrecoverable attachment placeholders must render as an unsent-style
  // system row, never a broken file card — even though they carry attachments.
  group('attachment-unavailable placeholders', () {
    test('missing_attachment_rows renders as a retracted system row', () {
      final rows = buildDisplayRows([
        _m(
          guid: 'miss',
          semanticKind: 'missing_attachment_rows',
          attachments: const [
            AttachmentModel(guid: 'a', downloadUrl: '', attachmentKind: 'file'),
          ],
        ),
      ], const MessageDisplayPrefs());
      expect(rows.single.kind, MessageRenderableKind.retracted);
    });

    test('empty_edited_residue renders as a retracted system row', () {
      expect(
        renderableKindFor(_m(semanticKind: 'empty_edited_residue')),
        MessageRenderableKind.retracted,
      );
    });
  });

  group('emoji preservation / control filtering', () {
    test('emoji-only messages are NOT control-like', () {
      expect(isControlLikeText('\u{1F600}'), isFalse); // 😀
      expect(isControlLikeText('\u{1F44D}\u{1F44D}'), isFalse); // 👍👍
      expect(displayText(_m(text: '\u{1F389}')), '\u{1F389}'); // 🎉 preserved
    });
    test('protocol artifacts ARE control-like', () {
      expect(isControlLikeText('+!'), isTrue);
      expect(isControlLikeText(r'+$'), isTrue);
      expect(isControlLikeText(''), isTrue);
    });
    test('real text + mixed emoji preserved', () {
      expect(displayText(_m(text: 'hi \u{1F600}')), 'hi \u{1F600}');
      expect(isControlLikeText('ok'), isFalse);
    });
  });

  group('display prefs: hide / merge', () {
    test('hideUnsupportedRows drops unknown but keeps failed outgoing', () {
      final msgs = [
        _m(guid: '1', text: 'hi'),
        _m(guid: '2', text: '+!'), // unknown (control-like)
        _m(
          guid: '3',
          isFromMe: true,
          text: 'oops',
          localState: LocalSendState.failed,
        ),
      ];
      final rows = buildDisplayRows(
        msgs,
        const MessageDisplayPrefs(hideUnsupportedRows: true),
      );
      final guids = rows.map((r) => r.message.guid).toList();
      expect(guids.contains('2'), isFalse); // unsupported hidden
      expect(guids.contains('3'), isTrue); // failed outgoing always kept
    });

    test(
      'mergeTapbacks attaches reactions to target, removes standalone rows',
      () {
        final msgs = [
          _m(guid: 't', text: 'hello'),
          _m(
            guid: 'r',
            associatedMessageType: 2000,
            associatedMessageGuid: 'p:0/t',
          ),
        ];
        final rows = buildDisplayRows(
          msgs,
          const MessageDisplayPrefs(mergeTapbacks: true),
        );
        expect(rows.length, 1); // reaction merged, not its own row
        expect(rows.first.message.guid, 't');
        expect(rows.first.reactions.length, 1);
      },
    );

    test('mergeTapbacks off keeps reaction as its own (system) row', () {
      final msgs = [
        _m(guid: 't', text: 'hello'),
        _m(
          guid: 'r',
          associatedMessageType: 2000,
          associatedMessageGuid: 'p:0/t',
        ),
      ];
      final rows = buildDisplayRows(
        msgs,
        const MessageDisplayPrefs(mergeTapbacks: false),
      );
      expect(rows.length, 2);
    });

    test('mergeConsecutiveSystem collapses a run of system rows', () {
      final msgs = [
        _m(guid: 'a', itemType: 2), // service
        _m(guid: 'b', itemType: 2), // service
        _m(guid: 'c', itemType: 2), // service
        _m(guid: 'd', text: 'real'),
      ];
      final rows = buildDisplayRows(
        msgs,
        const MessageDisplayPrefs(
          mergeConsecutiveSystem: true,
          mergeTapbacks: false,
        ),
      );
      // 3 system rows merged into 1 + the normal row.
      expect(rows.length, 2);
      final merged = rows.firstWhere((r) => r.isMergedSystem);
      expect(merged.mergedSystemCount, 3);
    });
  });

  group('contact matching by phone/email', () {
    test('matches phone + email and resolves contact id', () {
      final idx = ContactIndex.fromContacts([
        const ContactIdentity(
          id: 'c1',
          displayName: 'Jane Doe',
          phones: ['+1 (555) 123-4567'],
          emails: ['jane@iCloud.com'],
        ),
      ]);
      expect(idx.displayNameFor('+15551234567'), 'Jane Doe');
      expect(idx.displayNameFor('JANE@icloud.com'), 'Jane Doe');
      expect(idx.contactIdFor('555-123-4567'), 'c1');
      expect(idx.contactIdFor('jane@icloud.com'), 'c1');
      expect(idx.displayNameFor('+19998887777'), isNull);
    });
  });
}
