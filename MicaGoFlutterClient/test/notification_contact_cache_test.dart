import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/network/notification_contact_cache.dart';

void main() {
  group('notification contact cache (C60)', () {
    test('encode + decode round trip, normalized handles', () {
      final raw = encodeNotificationContactCache({
        '+15551234567': const NotificationContact(
          name: 'Alex Chen',
          avatarPath: '/x/alex.png',
        ),
        ' Alex@Example.COM ': const NotificationContact(name: 'Alex (Work)'),
        'noname@example.com': const NotificationContact(
          avatarPath: '/x/n.png',
        ),
      });

      final phone = decodeNotificationContact(raw, '+15551234567');
      expect(phone?.name, 'Alex Chen');
      expect(phone?.avatarPath, '/x/alex.png');

      // Lookup is case/whitespace-insensitive on both sides.
      final email = decodeNotificationContact(raw, 'alex@example.com');
      expect(email?.name, 'Alex (Work)');
      expect(email?.avatarPath, isNull);

      // Avatar-only entries survive (photo without a contact name).
      expect(
        decodeNotificationContact(raw, 'NONAME@example.com')?.avatarPath,
        '/x/n.png',
      );

      // Unknown handle / junk input → null, never a throw.
      expect(decodeNotificationContact(raw, 'stranger@x.com'), isNull);
      expect(decodeNotificationContact('not json', '+15551234567'), isNull);
      expect(decodeNotificationContact(raw, ''), isNull);
      expect(decodeNotificationContact(null, '+15551234567'), isNull);
    });

    test('empty entries are dropped and the cache is capped', () {
      final big = {
        for (var i = 0; i < notificationContactCacheMax + 50; i++)
          'user$i@example.com': NotificationContact(name: 'User $i'),
        'empty@example.com': const NotificationContact(),
      };
      final raw = encodeNotificationContactCache(big);
      expect(decodeNotificationContact(raw, 'empty@example.com'), isNull);
      // Cap respected: the first N entries are present, the overflow is not.
      expect(decodeNotificationContact(raw, 'user0@example.com'), isNotNull);
      var kept = 0;
      for (var i = 0; i < notificationContactCacheMax + 50; i++) {
        if (decodeNotificationContact(raw, 'user$i@example.com') != null) {
          kept++;
        }
      }
      expect(kept, notificationContactCacheMax);
    });
  });
}
