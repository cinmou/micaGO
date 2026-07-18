import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/network/notification_display.dart';
import 'package:mica_go/core/network/push_logic.dart';
import 'package:mica_go/core/network/push_service.dart';

void main() {
  group('C28 FCM options persistence (background-isolate init)', () {
    test('config → persisted map → FirebaseOptions round-trips', () {
      final cfg = {
        'configured': true,
        'apiKey': 'AIzaKEY',
        'appId': '1:123:android:abc',
        'messagingSenderId': '123',
        'projectId': 'my-proj',
        'storageBucket': 'my-proj.appspot.com',
      };
      final stored = fcmOptionsStorageMap(cfg);
      final decoded = jsonDecode(jsonEncode(stored)) as Map<String, dynamic>;
      final opts = firebaseOptionsFromMap(decoded);
      expect(opts.apiKey, 'AIzaKEY');
      expect(opts.appId, '1:123:android:abc');
      expect(opts.messagingSenderId, '123');
      expect(opts.projectId, 'my-proj');
      expect(opts.storageBucket, 'my-proj.appspot.com');
    });

    test('empty storageBucket maps to null (optional field)', () {
      final opts = firebaseOptionsFromMap({
        'apiKey': 'k',
        'appId': 'a',
        'messagingSenderId': 's',
        'projectId': 'p',
        'storageBucket': '',
      });
      expect(opts.storageBucket, isNull);
    });
  });

  group('C22 push decision logic (BlueBubbles dedup + routing)', () {
    test('foreground push runs catch-up only when the socket is down', () {
      // Socket connected → it already delivered the event → no catch-up (no dup).
      expect(pushShouldCatchUp(realtimeConnected: true), isFalse);
      // Socket down → push is the wake signal → run a delta catch-up.
      expect(pushShouldCatchUp(realtimeConnected: false), isTrue);
    });

    test('routes a tap to the chat GUID in the payload', () {
      expect(
        pushChatGuid({'chatGuid': 'iMessage;-;+15550001'}),
        'iMessage;-;+15550001',
      );
      expect(pushChatGuid({'chatGuid': ''}), isNull);
      expect(pushChatGuid({'type': 'message:new'}), isNull);
    });

    test('only shows a notification when there is something to show', () {
      expect(pushShouldNotify({'title': 'Jane', 'body': 'hi'}), isTrue);
      expect(
        pushShouldNotify({'title': '', 'body': ''}),
        isFalse,
      ); // preview off
      expect(pushShouldNotify({'type': 'test', 'title': 'x'}), isTrue);
    });
  });

  group('C30 notification formatting + reply', () {
    test('title falls back to a generic label when sender is absent', () {
      expect(notificationTitle({'title': 'Jane'}), 'Jane');
      expect(notificationTitle({'title': ''}), 'New message');
      expect(notificationTitle({}), 'New message');
    });

    test('body is null when preview is off', () {
      expect(notificationBody({'body': 'hello'}), 'hello');
      expect(notificationBody({'body': ''}), isNull);
      expect(notificationBody({}), isNull);
    });

    test('attachments use the same compact preview as the chat list', () {
      expect(
        notificationBody({
          'body': '',
          'hasAttachments': 'true',
          'previewMode': 'sender_and_text',
        }),
        '[附件]',
      );
      expect(
        notificationBody({
          'body': '',
          'hasAttachments': 'true',
          'previewMode': 'sender',
        }),
        isNull,
      );
    });

    test('timestamp accepts FCM string data', () {
      expect(
        notificationTimestampMs({'createdAt': '1782861203813'}),
        1782861203813,
      );
      expect(notificationTimestampMs({'createdAt': 123}), 123);
      expect(notificationTimestampMs({'createdAt': 'bad'}), isNull);
    });

    test('reply text is trimmed and empty input rejected', () {
      expect(cleanReplyText('  hi  '), 'hi');
      expect(cleanReplyText(''), isNull);
      expect(cleanReplyText('   '), isNull);
      expect(cleanReplyText(null), isNull);
    });
  });

  group('C31 notification title + preview', () {
    test('prefers an on-device contact name over everything', () {
      expect(
        messageNotificationTitle(
          contactName: 'Mom',
          serverTitle: '+15550001',
          handle: '+15550001',
        ),
        'Mom',
      );
    });

    test(
      'uses the server sender name when it is not a generic placeholder',
      () {
        expect(
          messageNotificationTitle(serverTitle: 'Jane', handle: '+15550001'),
          'Jane',
        );
        // Generic server titles fall through to the handle.
        expect(
          messageNotificationTitle(
            serverTitle: 'New message',
            handle: '+15550001',
          ),
          '+15550001',
        );
        expect(
          messageNotificationTitle(
            serverTitle: 'New iMessage',
            handle: 'a@b.com',
          ),
          'a@b.com',
        );
      },
    );

    test('falls back to the handle, then a generic label — never empty', () {
      expect(messageNotificationTitle(handle: '+15550001'), '+15550001');
      expect(messageNotificationTitle(), 'New message');
      expect(
        messageNotificationTitle(serverTitle: 'New message'),
        'New message',
      );
      expect(messageNotificationTitle(contactName: '   '), 'New message');
    });

    test('local body honors the preview mode (matches FCM privacy)', () {
      expect(localNotificationBody('hello', 'sender_and_text'), 'hello');
      expect(localNotificationBody('hello', 'sender'), isNull);
      expect(localNotificationBody('hello', 'none'), isNull);
      expect(localNotificationBody('   ', 'sender_and_text'), isNull);
      expect(localNotificationBody(null, 'sender_and_text'), isNull);
    });

    test('group notifications separate conversation title from sender', () {
      final data = {
        'chatGuid': 'any;+;group-guid',
        'title': 'Family',
        'conversationTitle': 'Family',
        'senderName': 'Alice',
        'handle': '+15550001',
        'isGroup': 'true',
      };
      expect(notificationIsGroup(data), isTrue);
      expect(notificationConversationTitle(data), 'Family');
      expect(notificationSenderName(data), 'Alice');
    });

    test('old group push payloads fall back from the chat GUID', () {
      final data = {'chatGuid': 'any;+;group-guid', 'title': 'New message'};
      expect(notificationIsGroup(data), isTrue);
      expect(notificationConversationTitle(data), 'Group chat');
    });

    test('test contact push uses the local test contact identity', () {
      final data = {
        'chatGuid': testContactChatGuid,
        'title': 'New message',
        'senderName': 'New message',
        'handle': testContactHandle,
      };
      expect(isTestContactPush(data), isTrue);
      expect(notificationSenderName(data), testContactDisplayName);
      expect(notificationConversationTitle(data), testContactDisplayName);
    });

    test(
      'dedup id is deterministic and positive (cross-isolate FCM/keep-alive)',
      () {
        // Same GUID → same id (so FCM + keep-alive collapse into one), different
        // GUID → different id. Must not depend on String.hashCode (per-isolate).
        final a = notificationIdForMessage('iMessage;-;+15550001/abc');
        final b = notificationIdForMessage('iMessage;-;+15550001/abc');
        final c = notificationIdForMessage('iMessage;-;+15550002/xyz');
        expect(a, b);
        expect(a, isNot(c));
        expect(a, greaterThanOrEqualTo(0));
        expect(notificationIdForMessage(null), notificationIdForMessage(''));
      },
    );
  });
}
