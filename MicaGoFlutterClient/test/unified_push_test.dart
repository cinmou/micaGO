import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/network/push_logic.dart';
import 'package:mica_go/core/network/unified_push.dart';

void main() {
  test('subscription token carries endpoint and WebPush keys', () {
    final token = unifiedPushToken(
      ' https://ntfy.example.com/upAbCdEfGhIjKl?up=1 ',
      'BCVxsr7N',
      'BTBZMqHH',
    );
    expect(jsonDecode(token!), {
      'endpoint': 'https://ntfy.example.com/upAbCdEfGhIjKl?up=1',
      'p256dh': 'BCVxsr7N',
      'auth': 'BTBZMqHH',
    });
    expect(unifiedPushHost(token), 'ntfy.example.com');
  });

  test('endpoint without encryption keys is not registrable', () {
    expect(unifiedPushToken('https://x.example/a', null, 'a'), isNull);
    expect(unifiedPushToken('https://x.example/a', 'k', ''), isNull);
    expect(unifiedPushToken('', 'k', 'a'), isNull);
  });

  test('decrypted payload decodes to the shared FCM data map', () {
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'type': 'message:new',
          'title': 'Alice',
          'body': '你好',
          'chatGuid': 'chat-1',
          'messageGuid': 'm-1',
        }),
      ),
    );
    final data = unifiedPushData(bytes, true)!;
    expect(data['title'], 'Alice');
    expect(pushShouldNotify(data), isTrue);
    expect(pushChatGuid(data), 'chat-1');
  });

  test('undecrypted or non-JSON content is never shown', () {
    final bytes = Uint8List.fromList(utf8.encode('{"title":"x"}'));
    expect(unifiedPushData(bytes, false), isNull);
    expect(unifiedPushData(Uint8List.fromList([0xff, 0x00]), true), isNull);
    expect(
      unifiedPushData(Uint8List.fromList(utf8.encode('[1,2]')), true),
      isNull,
    );
  });

  test('distributor labels', () {
    expect(distributorLabel('io.heckel.ntfy'), 'ntfy');
    expect(distributorLabel(micaGoAndroidPackage), 'FCM (Google Play)');
    expect(distributorLabel('$micaGoAndroidPackage.dev'), 'FCM (Google Play)');
    expect(distributorLabel('org.example.other'), 'org.example.other');
  });
}
