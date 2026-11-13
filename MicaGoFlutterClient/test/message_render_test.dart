import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/features/chats/message_render.dart';
import 'package:mica_go/features/chats/models/message_model.dart';

MessageModel _msg({
  String? text,
  bool isFromMe = false,
  bool isRead = false,
  bool isDelivered = false,
  int? dateRead,
  int? dateDelivered,
  String? handleId,
  List<AttachmentModel> attachments = const [],
  int? associatedType,
  String? associatedGuid,
  int itemType = 0,
  int groupActionType = 0,
  int errorCode = 0,
  bool isEdited = false,
  int? dateEdited,
  bool isDebugOnly = false,
  bool cacheHasAttachments = false,
  String? semanticKind,
  String? renderRecommendation,
  String? unsupportedReason,
  String? tempId,
  String? balloonBundleId,
  bool payloadDataPresent = false,
  LocalSendState localState = LocalSendState.confirmed,
}) {
  return MessageModel(
    guid: 'g',
    text: text,
    isFromMe: isFromMe,
    isRead: isRead,
    isDelivered: isDelivered,
    dateRead: dateRead,
    dateDelivered: dateDelivered,
    handleId: handleId,
    attachments: attachments,
    associatedMessageType: associatedType,
    associatedMessageGuid: associatedGuid,
    itemType: itemType,
    groupActionType: groupActionType,
    errorCode: errorCode,
    isEdited: isEdited,
    dateEdited: dateEdited,
    isDebugOnly: isDebugOnly,
    cacheHasAttachments: cacheHasAttachments,
    semanticKind: semanticKind,
    renderRecommendation: renderRecommendation,
    unsupportedReason: unsupportedReason,
    balloonBundleId: balloonBundleId,
    payloadDataPresent: payloadDataPresent,
    tempId: tempId,
    localState: localState,
  );
}

void main() {
  group('control-like text filter', () {
    test('flags "+!" and "+\$" artifacts', () {
      expect(isControlLikeText('+!'), isTrue);
      expect(isControlLikeText('+\$'), isTrue);
    });
    test('flags empty / object-replacement only', () {
      expect(isControlLikeText(''), isTrue);
      expect(isControlLikeText('￼'), isTrue);
    });
    test('does not flag real text or "+1"', () {
      expect(isControlLikeText('Hello there'), isFalse);
      expect(isControlLikeText('+1'), isFalse);
      expect(isControlLikeText('你好'), isFalse);
    });
    test('does not flag punctuation-only messages', () {
      for (final t in ['?', '??', '...', '!', '?!', '-_-']) {
        expect(isControlLikeText(t), isFalse, reason: t);
      }
      expect(displayText(_msg(text: '?')), '?');
    });
    test('displayText strips placeholder and drops control payloads', () {
      expect(displayText(_msg(text: '￼Hello')), 'Hello');
      expect(displayText(_msg(text: '�')), isNull);
      expect(displayText(_msg(text: '+!')), isNull);
      expect(displayText(_msg(text: '   ')), isNull);
    });
  });

  group('renderableKindFor', () {
    test('normal for real text', () {
      expect(renderableKindFor(_msg(text: 'Hi')), MessageRenderableKind.normal);
    });
    test('attachmentOnly when no text but attachments', () {
      final m = _msg(
        attachments: const [
          AttachmentModel(
            guid: 'a',
            downloadUrl: '/x',
            attachmentKind: 'image',
          ),
        ],
      );
      expect(renderableKindFor(m), MessageRenderableKind.attachmentOnly);
    });
    test('service for group/item events', () {
      expect(
        renderableKindFor(_msg(itemType: 2)),
        MessageRenderableKind.service,
      );
    });
    test('reaction for associated message', () {
      expect(
        renderableKindFor(
          _msg(associatedType: 2000, associatedGuid: 'p:0/abc'),
        ),
        MessageRenderableKind.reaction,
      );
    });
    test('interactive app balloons render while update rows stay hidden', () {
      const pollsBundle =
          'com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.messages.Polls';
      expect(
        renderableKindFor(
          _msg(
            text: '�',
            balloonBundleId: pollsBundle,
            payloadDataPresent: true,
          ),
        ),
        MessageRenderableKind.normal,
      );
      expect(
        isInteractiveUpdate(
          _msg(
            text: ' ',
            associatedType: 4000,
            associatedGuid: 'BCF0CED8-2CD5-4F75-B89B-DCF030DEC71D',
            balloonBundleId: pollsBundle,
            payloadDataPresent: true,
          ),
        ),
        isTrue,
      );
    });
    test(
      'Digital Touch without an attachment renders as an interactive card',
      () {
        expect(
          renderableKindFor(
            _msg(
              text: '￼',
              balloonBundleId: 'com.apple.DigitalTouchBalloonProvider',
              payloadDataPresent: true,
            ),
          ),
          MessageRenderableKind.normal,
        );
      },
    );
    test('unknown for control-only text and no attachments', () {
      expect(
        renderableKindFor(_msg(text: '+!')),
        MessageRenderableKind.unknown,
      );
      expect(
        renderableKindFor(_msg(text: null)),
        MessageRenderableKind.unknown,
      );
    });
    test('server debug-only recommendation renders as unknown', () {
      expect(
        renderableKindFor(_msg(text: 'hidden', isDebugOnly: true)),
        MessageRenderableKind.unknown,
      );
    });
    test(
      'empty edited residue renders as an unsent system row, not a bubble',
      () {
        final m = _msg(
          isEdited: true,
          semanticKind: 'empty_edited_residue',
          renderRecommendation: 'system',
          unsupportedReason: 'empty_edited_residue',
        );
        // C26: unrecoverable placeholders present as an unsent/retracted row
        // (no longer a hidden "unknown"), while the diagnostic reason is retained
        // for Message Info / Debug.
        expect(renderableKindFor(m), MessageRenderableKind.retracted);
        final cls = classifyMessage(m);
        expect(cls.isUnsupported, isFalse);
        expect(cls.reason, UnsupportedReason.emptyEditedResidue);
      },
    );
    test('normal edited text stays a normal message', () {
      expect(
        renderableKindFor(_msg(text: 'fixed typo', isEdited: true)),
        MessageRenderableKind.normal,
      );
    });
  });

  group('edited marker', () {
    test('shows marker for edited non-retracted messages', () {
      expect(editedMarker(_msg(text: 'hi', isEdited: true)), 'Edited');
      expect(editedMarker(_msg(text: 'hi')), isNull);
    });
  });

  group('chat list previews', () {
    test('uses compact attachment placeholders', () {
      expect(
        messagePreviewText(
          _msg(
            attachments: const [
              AttachmentModel(
                guid: 'img',
                downloadUrl: '/img',
                attachmentKind: 'image',
              ),
            ],
          ),
        ),
        '[Attachment]',
      );
      expect(
        messagePreviewText(
          _msg(
            attachments: const [
              AttachmentModel(
                guid: 'voice',
                downloadUrl: '/voice',
                attachmentKind: 'audio',
                isVoiceMessage: true,
              ),
            ],
          ),
        ),
        '[Attachment]',
      );
      expect(messagePreviewText(_msg()), '[Attachment]');
    });

    test('sanitizes stale server/cache previews', () {
      expect(chatListPreviewText('￼', hasMessage: true), '[Attachment]');
      expect(chatListPreviewText('obj', hasMessage: true), '[Attachment]');
      expect(chatListPreviewText('Message', hasMessage: true), '[Attachment]');
      expect(chatListPreviewText('（图片）', hasMessage: true), '[Attachment]');
      expect(chatListPreviewText('', hasMessage: false), '');
    });
  });

  group('deliveryStateFor', () {
    test('incoming never shows outgoing status', () {
      expect(
        deliveryStateFor(_msg(isFromMe: false, isDelivered: true)),
        MessageDeliveryState.incoming,
      );
    });
    test('unknown send outcome waits for confirmation', () {
      expect(
        deliveryStateFor(
          _msg(isFromMe: true, tempId: 't', localState: LocalSendState.pending),
        ),
        MessageDeliveryState.awaitingConfirmation,
      );
      expect(
        deliveryStateFor(
          _msg(isFromMe: true, tempId: 't', localState: LocalSendState.sending),
        ),
        MessageDeliveryState.sending,
      );
    });
    test('sent_unconfirmed still waits for a server message', () {
      expect(
        deliveryStateFor(
          _msg(
            isFromMe: true,
            tempId: 't',
            localState: LocalSendState.sentUnconfirmed,
          ),
        ),
        MessageDeliveryState.awaitingConfirmation,
      );
    });
    test('failed from local state or error code', () {
      expect(
        deliveryStateFor(
          _msg(isFromMe: true, localState: LocalSendState.failed),
        ),
        MessageDeliveryState.failed,
      );
      expect(
        deliveryStateFor(_msg(isFromMe: true, errorCode: 22)),
        MessageDeliveryState.failed,
      );
    });
    test('read > delivered > sent precedence', () {
      expect(
        deliveryStateFor(_msg(isFromMe: true, isRead: true)),
        MessageDeliveryState.read,
      );
      expect(
        deliveryStateFor(_msg(isFromMe: true, isDelivered: true)),
        MessageDeliveryState.delivered,
      );
      expect(deliveryStateFor(_msg(isFromMe: true)), MessageDeliveryState.sent);
    });
  });

  group('resolveSenderLabel', () {
    test('You for outgoing', () {
      expect(resolveSenderLabel(_msg(isFromMe: true), isGroup: true), 'You');
    });
    test('contact name preferred', () {
      expect(
        resolveSenderLabel(
          _msg(handleId: '+15551234567'),
          isGroup: true,
          contactName: 'Jane',
        ),
        'Jane',
      );
    });
    test('falls back to handle then Unknown', () {
      expect(
        resolveSenderLabel(_msg(handleId: '+15551234567'), isGroup: true),
        '+15551234567',
      );
      expect(
        resolveSenderLabel(_msg(handleId: null), isGroup: true),
        'Unknown',
      );
    });
  });
}
