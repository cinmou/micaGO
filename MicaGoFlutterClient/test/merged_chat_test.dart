import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/features/chats/chat_service.dart';
import 'package:mica_go/features/chats/models/chat_summary.dart';
import 'package:mica_go/features/chats/models/merged_chat.dart';

ChatSummary chat(String guid, String handle, String effective, {int? at}) =>
    ChatSummary.fromJson({
      'guid': guid,
      'chatIdentifier': handle,
      'effectiveService': effective,
      'latestRenderableAt': at,
    });

void main() {
  test('read routes with stale counts do not keep merged unread state', () {
    final read = ChatSummary(guid: 'phone', hasUnread: false, unreadCount: 8);
    final unread = ChatSummary(guid: 'email', hasUnread: true, unreadCount: 1);
    final merged = MergedChat(key: 'contact', routes: [read, unread]);
    expect(merged.hasUnread, isTrue);
    expect(merged.unreadCount, 1);
    final seen = MergedChat(
      key: 'contact',
      routes: [read, unread.copyWith(hasUnread: false)],
    );
    expect(seen.hasUnread, isFalse);
    expect(seen.unreadCount, 0);
  });

  group('virtual contact merge (client-only)', () {
    test(
      'iMessage-phone + iMessage-email + SMS-phone for one contact merge',
      () {
        final chats = [
          chat('iMessage;-;+1555', '+1555', 'imessage', at: 100),
          chat('iMessage;-;a@b.com', 'a@b.com', 'imessage', at: 90),
          chat('SMS;-;+1555', '+1555', 'sms', at: 110),
        ];
        // All three resolve to the same contact.
        final merged = mergeChatsByContact(chats, (_) => 'contact-7');
        expect(merged.length, 1);
        expect(merged.first.isMerged, isTrue);
        expect(merged.first.routes.length, 3);
      },
    );

    test('default route prefers iMessage even if SMS is more recent', () {
      final chats = [
        chat('SMS;-;+1555', '+1555', 'sms', at: 200), // newest
        chat('iMessage;-;+1555', '+1555', 'imessage', at: 100),
      ];
      final merged = mergeChatsByContact(chats, (_) => 'c1');
      expect(merged.first.primary.service, ChatService.imessage);
      // SMS is still present as a selectable route, just not the default.
      expect(merged.first.routes.last.service, ChatService.sms);
    });

    test('unresolved handle is NOT merged (safety over over-merging)', () {
      final chats = [
        chat('iMessage;-;+1555', '+1555', 'imessage'),
        chat('SMS;-;+1999', '+1999', 'sms'),
      ];
      // contactIdFor returns null → no confident contact → keep separate.
      final merged = mergeChatsByContact(chats, (_) => null);
      expect(merged.length, 2);
      expect(merged.every((m) => !m.isMerged), isTrue);
    });

    test('group chats are never merged', () {
      final group = ChatSummary.fromJson({
        'guid': 'g1',
        'displayName': 'Team',
        'effectiveService': 'imessage',
      });
      final merged = mergeChatsByContact([group], (_) => 'contact-x');
      expect(merged.length, 1);
      expect(merged.first.isMerged, isFalse);
    });

    test('different contacts stay separate', () {
      final chats = [
        chat('iMessage;-;+1555', '+1555', 'imessage'),
        chat('iMessage;-;+1999', '+1999', 'imessage'),
      ];
      var n = 0;
      final merged = mergeChatsByContact(chats, (_) => 'contact-${n++}');
      expect(merged.length, 2);
    });

    test('lastMessageAt + preview reflect the newest route', () {
      final chats = [
        chat('iMessage;-;+1555', '+1555', 'imessage', at: 100),
        ChatSummary.fromJson({
          'guid': 'SMS;-;+1555',
          'chatIdentifier': '+1555',
          'effectiveService': 'sms',
          'latestRenderableAt': 200,
          'latestRenderablePreview': 'newest sms',
        }),
      ];
      final merged = mergeChatsByContact(chats, (_) => 'c1').first;
      expect(merged.lastMessageAt, 200);
      expect(merged.lastMessagePreview, 'newest sms');
    });

    test(
      'unread count excludes already-read routes; hasUnread is per-route derived',
      () {
        final merged = mergeChatsByContact([
          ChatSummary.fromJson({
            'guid': 'iMessage;-;+1555',
            'chatIdentifier': '+1555',
            'effectiveService': 'imessage',
            'unreadCount': 2,
            'hasUnread': true,
          }),
          ChatSummary.fromJson({
            'guid': 'SMS;-;+1555',
            'chatIdentifier': '+1555',
            'effectiveService': 'sms',
            'unreadCount': 3,
          }),
        ], (_) => 'c1').single;

        expect(merged.unreadCount, 2);
        // C43: the dot is the derived watermark state — any unread route makes the
        // merged contact unread, independent of the count.
        expect(merged.hasUnread, isTrue);
      },
    );
  });
}
