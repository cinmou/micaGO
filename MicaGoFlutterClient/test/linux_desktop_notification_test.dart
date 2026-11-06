import 'dart:convert';
import 'dart:ui' as ui;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:mica_go/core/network/linux_notification_avatar.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/network/notification_display.dart';
import 'package:mica_go/core/app_controller.dart';
import 'package:mica_go/core/network/push_service.dart';
import 'package:mica_go/core/platform/linux_desktop.dart';

class _Notifications implements FlutterLocalNotificationsPlugin {
  final shown = <({String? body, NotificationDetails? details})>[];
  final cancelled = <int>[];
  bool initializedForLinux = false;

  @override
  Future<bool?> initialize(
    InitializationSettings settings, {
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
    onDidReceiveBackgroundNotificationResponse,
  }) async {
    initializedForLinux = settings.linux != null;
    return true;
  }

  @override
  Future<NotificationAppLaunchDetails?> getNotificationAppLaunchDetails() =>
      throw UnimplementedError('Linux does not implement cold-launch details');

  @override
  Future<void> show(
    int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails, {
    String? payload,
  }) async {
    shown.add((body: body, details: notificationDetails));
  }

  @override
  Future<void> cancel(int id, {String? tag}) async => cancelled.add(id);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DesktopApp implements AppController {
  @override
  bool get hasProfile => true;
  @override
  void noteNotificationPermission(bool? granted) {}
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isSetter) return null;
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.linux);
  tearDown(() async {
    await clearSuppressedLinuxNotifications((_, _) => true);
    debugDefaultTargetPlatformOverride = null;
  });

  Future<void> post(_Notifications plugin, String guid, int timestamp) =>
      showMessageNotification(
        plugin,
        chatGuid: 'chat',
        messageGuid: guid,
        senderName: 'Alice',
        conversationTitle: 'Alice',
        body: '<b>hello</b> & bye',
        timestampMs: timestamp,
        deviceId: 'device',
      );

  test(
    'Linux initializes without Android keep-alive or unsupported launch APIs',
    () async {
      final plugin = _Notifications();
      final push = PushService(_DesktopApp(), localNotifications: plugin);
      await push.start();
      expect(plugin.initializedForLinux, isTrue);
      expect(push.localReady, isTrue);
      expect(push.available, isFalse);
      push.dispose();
    },
  );

  test(
    'desktop notices escape markup, deduplicate and use Linux details',
    () async {
      final plugin = _Notifications();
      await post(plugin, 'message-1', 100);
      await post(plugin, 'message-1', 100);
      expect(plugin.shown, hasLength(1));
      expect(plugin.shown.single.body, '&lt;b&gt;hello&lt;/b&gt; &amp; bye');
      expect(plugin.shown.single.details?.linux, isNotNull);
      expect(plugin.shown.single.details?.android, isNull);
    },
  );

  test(
    'sender portraits are circular, refresh on changes, and fall back safely',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'micago-notice-avatar-',
      );
      addTearDown(() => directory.delete(recursive: true));
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final sender = await File(
        '${directory.path}/sender.png',
      ).writeAsBytes(base64Decode(_redPhoto));
      final conversation = await File(
        '${directory.path}/conversation.png',
      ).writeAsBytes(base64Decode(_bluePhoto));
      final plugin = _Notifications();
      Future<void> show(String guid) => showMessageNotification(
        plugin,
        chatGuid: 'avatar-chat',
        messageGuid: guid,
        senderName: 'Alice',
        conversationTitle: 'Group',
        isGroup: true,
        avatarFilePath: sender.path,
        conversationAvatarFilePath: conversation.path,
      );
      Future<Uint8List> pixels(String path) async {
        final codec = await ui.instantiateImageCodec(
          await File(path).readAsBytes(),
        );
        final image = (await codec.getNextFrame()).image;
        try {
          expect(image.width, 128);
          expect(image.height, 128);
          final data = (await image.toByteData())!;
          return data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
        } finally {
          image.dispose();
          codec.dispose();
        }
      }

      await show('sender-round-photo');
      final first = plugin.shown.last.details!.linux!.icon as FilePathLinuxIcon;
      final rgba = await pixels(first.path);
      expect(rgba[3], 0); // Transparent outside the circle.
      final middle = (64 * 128 + 64) * 4;
      expect(rgba.sublist(middle, middle + 4), [255, 0, 0, 255]);
      await show('same-sender-photo');
      expect(
        (plugin.shown.last.details!.linux!.icon as FilePathLinuxIcon).path,
        first.path,
      );
      await sender.writeAsBytes(base64Decode(_bluePhoto));
      await show('updated-sender-photo');
      final updated =
          plugin.shown.last.details!.linux!.icon as FilePathLinuxIcon;
      expect(updated.path, isNot(first.path));
      await sender.writeAsBytes([1, 2, 3]);
      await show('invalid-sender-falls-back-to-group');
      final fallback =
          plugin.shown.last.details!.linux!.icon as FilePathLinuxIcon;
      final blue = await pixels(fallback.path);
      expect(blue.sublist(middle, middle + 4), [0, 0, 255, 255]);
      await sender.delete();
      await conversation.delete();
      await show('missing-all-photos');
      expect(plugin.shown.last.details!.linux!.icon, isNull);
      await clearLinuxNotificationAvatars();
      expect(
        await Directory(
          '${directory.path}/linux-notification-avatars',
        ).exists(),
        isFalse,
      );
    },
  );

  test('read cutoff never clears a newer notification', () async {
    final plugin = _Notifications();
    await post(plugin, 'old', 100);
    await post(plugin, 'new', 200);
    await cancelLinuxNotificationThrough('chat', 100);
    expect(plugin.cancelled, isEmpty);
    await cancelLinuxNotificationThrough('chat', 200);
    expect(plugin.cancelled, hasLength(1));
  });

  test('hiding or muting removes already posted notifications', () async {
    final plugin = _Notifications();
    await post(plugin, 'message', 100);
    await clearSuppressedLinuxNotifications(
      (chat, message) => chat == 'chat' && message == 'message',
    );
    expect(plugin.cancelled, hasLength(1));
  });

  test('desktop text preference retains system accessibility scaling', () {
    const scaler = DesktopTextScaler(TextScaler.linear(1.5), 1.2);
    expect(scaler.scale(20), 36);
  });
}

const _redPhoto =
    'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKElEQVR4nO3NMQEAAAjDMMC/ZzDBvlRA01vZJvwHAAAAAAAAAAAAbx2jxAE/i2AjOgAAAABJRU5ErkJggg==';

const _bluePhoto =
    'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKUlEQVR4nO3NMQEAAAjDsIF/z2ACvlRAU8nks369AwAAAAAAAAAAgMMWocYBP7wfsd0AAAAASUVORK5CYII=';
