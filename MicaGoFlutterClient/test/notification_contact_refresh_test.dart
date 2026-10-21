import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/app_controller.dart';
import 'package:mica_go/core/network/notification_contact_cache.dart';
import 'package:mica_go/core/storage/local_cache_store.dart';
import 'package:mica_go/core/storage/secure_store.dart';
import 'package:mica_go/features/chats/models/chat_summary.dart';

class _Store implements SecureStore {
  final values = <String, String>{};
  bool failWrite = false;
  @override
  Future<void> writeValue(String key, String value) async {
    if (failWrite) throw StateError('storage unavailable');
    values[key] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Cache extends LocalCacheStore {
  List<ChatSummary> rows = [];
  @override
  Future<List<ChatSummary>> listChats({
    bool includeDebug = false,
    bool includeHidden = false,
  }) async => rows;
}

class _App extends AppController {
  _App({required super.store, required this.fixture});
  final _Cache fixture;
  @override
  LocalCacheStore get cache => fixture;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const route = ChatSummary(
    guid: 'chat-alex',
    chatIdentifier: 'Alex@Example.com',
  );
  late _Store store;
  late _Cache cache;
  late _App app;
  NotificationContact? lookup(String handle) => decodeNotificationContact(
    store.values[notificationContactCacheKey],
    handle,
  );

  setUp(() {
    store = _Store();
    cache = _Cache()..rows = [route];
    app = _App(store: store, fixture: cache);
  });
  tearDown(() => app.dispose());

  test(
    'late contact loading refreshes offline names and photo immediately',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'micago-notif-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await app.syncNotificationContactCache(cache.rows);
      expect(lookup('alex@example.com'), isNull);
      final bytes = Uint8List.fromList([137, 80, 78, 71]);
      app.contactNameResolver = (_) => 'Alex';
      app.contactAvatarResolver = (_) async => bytes;
      await app.refreshNotificationContactCache();
      final contact = lookup('alex@example.com');
      expect(contact?.name, 'Alex');
      expect(contact?.avatarPath, isNotNull);
      expect(await File(contact!.avatarPath!).readAsBytes(), bytes);
      app.contactNameResolver = (_) => null;
      app.contactAvatarResolver = (_) async => null;
      await app.refreshNotificationContactCache();
      expect(lookup('alex@example.com'), isNull);
    },
  );

  test(
    'group-only senders and new routes bypass unchanged-roster throttle',
    () async {
      app.contactNameResolver = (handle) => 'Name $handle';
      await app.syncNotificationContactCache(cache.rows);
      await app.syncNotificationContactCache([
        route,
        const ChatSummary(
          guid: 'group',
          isGroupRaw: true,
          participants: [' +15550001 ', 'Alex@Example.com'],
        ),
      ]);
      expect(lookup('+15550001')?.name, 'Name +15550001');
      expect(lookup('alex@example.com')?.name, 'Name alex@example.com');
    },
  );

  test('failed writes do not throttle the next attempt', () async {
    app.contactNameResolver = (_) => 'Alex';
    store.failWrite = true;
    await app.syncNotificationContactCache(cache.rows);
    store.failWrite = false;
    await app.syncNotificationContactCache(cache.rows);
    expect(lookup('alex@example.com')?.name, 'Alex');
  });

  test(
    'slow old photo reads cannot overwrite a later contacts refresh',
    () async {
      final photo = Completer<Uint8List?>();
      final started = Completer<void>();
      app.contactNameResolver = (_) => 'Old name';
      app.contactAvatarResolver = (_) {
        started.complete();
        return photo.future;
      };
      final oldWrite = app.syncNotificationContactCache(cache.rows);
      await started.future;
      app.contactNameResolver = (_) => 'New name';
      app.contactAvatarResolver = (_) async => null;
      final newWrite = app.refreshNotificationContactCache();
      photo.complete(null);
      await Future.wait([oldWrite, newWrite]);
      expect(lookup('alex@example.com')?.name, 'New name');
    },
  );
}
