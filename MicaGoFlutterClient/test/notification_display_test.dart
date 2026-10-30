import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:mica_go/core/network/notification_display.dart';
import 'package:mica_go/core/network/notification_store.dart';
import 'package:mica_go/core/network/push_logic.dart';
import 'package:micago_conversations/micago_conversations.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shown = <Map>[];
  final plugin = FlutterLocalNotificationsPlugin();
  setUpAll(() async {
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp(
      'micago-notification-test-',
    );
    await databaseFactory.setDatabasesPath(dir.path);
    addTearDown(() async {
      await dir.delete(recursive: true);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dexterous.com/flutter/local_notifications'),
          (call) async {
            if (call.method == 'show') shown.add(call.arguments as Map);
            return true;
          },
        );
    await plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('icon'),
      ),
    );
  });
  test(
    'native MessagingStyle keeps distinct people and offers explicit reply/read actions',
    () async {
      Future<void> show(String sender, int at, String resource) =>
          showMessageNotification(
            plugin,
            chatGuid: 'group',
            messageGuid: 'm$at',
            deviceId: 'device',
            senderName: 'Same name',
            senderKey: sender,
            conversationTitle: 'Group',
            body: 'hello',
            timestampMs: at,
            isGroup: true,
            avatarDrawableResource: resource,
          );
      await show('account-a', 100, 'avatar_a');
      await show('account-b', 200, 'avatar_b');
      final notification = shown.last;
      final android = notification['platformSpecifics'] as Map;
      final style = android['styleInformation'] as Map;
      final people = (style['messages'] as List)
          .map((m) => (m as Map)['person'] as Map)
          .toList();
      expect(people.map((p) => p['key']), ['account-a', 'account-b']);
      expect(people.map((p) => p['icon']), ['avatar_a', 'avatar_b']);
      expect((android['actions'] as List).map((a) => (a as Map)['id']), [
        notificationReplyActionId,
        notificationReadActionId,
      ]);
      expect(
        NotificationTarget.parse(
          notification['payload'] as String,
        )?.readThrough,
        200,
      );
    },
  );
  test(
    'unknown message time never marks all history read using push dispatch time',
    () async {
      await showMessageNotification(
        plugin,
        chatGuid: 'unknown',
        messageGuid: 'test',
        deviceId: 'device',
        senderName: 'A',
        conversationTitle: 'A',
      );
      final android = shown.last['platformSpecifics'] as Map;
      expect((android['actions'] as List).length, 1);
      expect(
        NotificationTarget.parse(shown.last['payload'] as String)?.readThrough,
        isNull,
      );
      expect(notificationTimestampMs({'createdAt': 999999}), isNull);
    },
  );
  test(
    'transactional buffers isolate devices and retain later arrivals after read',
    () async {
      BufferedNotifMessage message(int at) => BufferedNotifMessage(
        guid: '$at',
        sender: 'A',
        senderKey: 'a',
        text: '$at',
        ts: at,
        readThrough: at,
      );
      await Future.wait([
        for (var i = 1; i <= 6; i++)
          appendChatNotification('route', message(i), deviceId: 'a'),
      ]);
      await clearChatNotificationBuffer('route', through: 3, deviceId: 'a');
      final remaining = await appendChatNotification(
        'route',
        message(6),
        deviceId: 'a',
      );
      expect(remaining.map((m) => m.ts), [4, 5, 6]);
      final other = await appendChatNotification(
        'route',
        message(100),
        deviceId: 'b',
      );
      expect(other.map((m) => m.ts), [100]);
    },
  );
  test(
    'conversation bridge passes route/device metadata and no credentials',
    () async {
      Map? args;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidConversations.channel, (call) async {
            args = call.arguments as Map;
            return 'conversation-id';
          });
      expect(
        await AndroidConversations.publish(
          chatGuid: 'route',
          deviceId: 'device',
          title: 'A',
          payload: notificationPayload('route', 'device'),
        ),
        'conversation-id',
      );
      expect(
        args!.keys,
        unorderedEquals([
          'chatGuid',
          'deviceId',
          'title',
          'payload',
          'avatarPath',
          'personName',
          'personKey',
          'personAvatarPath',
        ]),
      );
    },
  );
}
