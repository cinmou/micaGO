import 'package:mica_go/core/network/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:mica_go/core/ui/top_banner.dart';
import 'package:mica_go/core/storage/media_cache.dart';
import 'package:mica_go/core/storage/local_cache_store.dart';
import 'package:mica_go/features/chats/chat_list_screen.dart';
import 'package:mica_go/features/contacts/contacts_service.dart';
import 'package:mica_go/features/settings/message_display_controller.dart';
import 'package:mica_go/core/l10n/app_localizations.dart';
import 'package:mica_go/features/home/connection_notice_host.dart';
import 'package:mica_go/features/chats/chat_list_controller.dart';
import 'package:mica_go/features/chats/models/chat_summary.dart';

import 'package:mica_go/core/app_controller.dart';
import 'package:mica_go/app/router.dart';
import 'package:mica_go/core/models/connection_profile.dart';
import 'package:mica_go/core/storage/secure_store.dart';
import 'package:mica_go/core/network/connection_candidate.dart';

class _MemoryStore implements SecureStore {
  ConnectionProfile? _saved;
  final Map<String, String> _values = {};
  bool _contactsEnabled = false;

  @override
  Future<bool> compatibilityStorageEnabled() async => false;
  @override
  Future<void> prepareCredentialStorage({
    Future<bool> Function()? confirmCompatibility,
  }) async {}

  @override
  Future<ConnectionProfile?> loadProfile() async => _saved;

  @override
  Future<void> saveProfile(ConnectionProfile profile) async {
    _saved = profile;
  }

  @override
  Future<void> clearProfile() async {
    _saved = null;
  }

  @override
  Future<bool> contactsMatchingEnabled() async => _contactsEnabled;

  @override
  Future<void> setContactsMatchingEnabled(bool enabled) async {
    _contactsEnabled = enabled;
  }

  @override
  Future<String?> readValue(String key) async => _values[key];

  @override
  Future<void> writeValue(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> deleteValue(String key) async {
    _values.remove(key);
  }
}

void main() {
  test(
    'sleep and resume suppress transient read errors, never authentication',
    () {
      final app = AppController(store: _MemoryStore());
      addTearDown(app.dispose);
      final generation = app.foregroundGeneration;
      app.setForeground(false);
      expect(
        app.suppressReadFailure(
          const ApiException(message: 'test', code: 'timeout'),
          requestGeneration: generation,
        ),
        isTrue,
      );
      app.setForeground(true);
      expect(app.isForegroundRecovering, isTrue);
      expect(
        app.suppressReadFailure(
          const ApiException(message: 'test', code: 'network_error'),
          requestGeneration: generation,
        ),
        isTrue,
      );
      expect(
        app.suppressReadFailure(
          const ApiException(
            message: 'test',
            code: 'unauthorized',
            statusCode: 401,
          ),
          requestGeneration: generation,
        ),
        isFalse,
      );
      expect(
        app.suppressReadFailure(
          const ApiException(message: 'test', code: 'invalid_response'),
          requestGeneration: generation,
        ),
        isFalse,
      );
    },
  );

  testWidgets('rejected session cannot navigate back to cached home', (
    tester,
  ) async {
    final app = _PairingApp(store: _MemoryStore());
    final profile = ConnectionProfile(
      baseUrl: 'https://relay.example',
      token: 'credential',
      deviceId: 'device',
    );
    await app.saveAndActivate(profile);
    app.rejectCredential(profile);
    final router = createRouter(app);
    addTearDown(router.dispose);
    addTearDown(app.dispose);
    addTearDown(() {
      MediaCache.instance.accessAllowed = true;
      TopBanner.blocked = false;
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: app,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    router.go(Routes.home);
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, Routes.connection);
    expect(find.byType(ChatListScreen), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('left swipe hides with undo and right swipe marks read', (
    tester,
  ) async {
    final store = _MemoryStore();
    final cache = _ChatFixtureCache();
    cache.metadata['read_state.v1'] =
        '{"serverId":"test-server","rows":{"row":100},"pending":{},"marks":{},"pendingMarks":{}}';
    cache.metadata['chat_preferences.v1'] =
        '{"serverId":"test-server","revision":0,"rows":[],"queue":[],"conflicts":[],"legacy":[]}';
    cache.rows = [ChatSummary(guid: 'row', hasUnread: true, unreadCount: 1)];
    final app = _CachedApp(store: store, fixture: cache);
    final contacts = ContactsService(store: store);
    final display = MessageDisplayController(store: store);
    addTearDown(app.dispose);
    addTearDown(contacts.dispose);
    addTearDown(display.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppController>.value(value: app),
          ChangeNotifierProvider<ContactsService>.value(value: contacts),
          ChangeNotifierProvider<MessageDisplayController>.value(
            value: display,
          ),
        ],
        child: MaterialApp(
          home: Scaffold(body: ChatListScreen(onOpen: (_) {})),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('chat-row-chat:row'));
    await tester.longPress(row);
    await tester.pumpAndSettle();
    expect(find.text('Mark read'), findsOneWidget);
    expect(find.text(MicaLocalizations.current.t('chat.pin')), findsOneWidget);
    await tester.tap(find.text('Mark read'));
    await tester.pumpAndSettle();
    expect(cache.rows.single.hasUnread, false);
    await tester.drag(row, const Offset(650, 0));
    await tester.pumpAndSettle();
    expect(app.chatPreferences.isHidden('row'), false);
    await tester.longPress(row);
    await tester.pumpAndSettle();
    expect(find.text('Mark unread'), findsOneWidget);
    await tester.tap(find.text('Mark unread'));
    await tester.pumpAndSettle();
    expect(cache.rows.single.hasUnread, true);
    await tester.drag(row, const Offset(650, 0));
    await tester.pumpAndSettle();
    expect(cache.rows.single.hasUnread, false);
    await tester.drag(row, const Offset(-650, 0));
    await tester.pumpAndSettle();
    expect(app.chatPreferences.isHidden('row'), true);
    expect(row, findsNothing);
    final snack = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snack.duration, const Duration(seconds: 5));
    expect(snack.persist, false);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(app.chatPreferences.isHidden('row'), false);
    expect(row, findsOneWidget);
    await tester.drag(row, const Offset(-650, 0));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsNothing);
    expect(app.chatPreferences.isHidden('row'), true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'read-watermark state clears row emphasis despite stale unread count',
    (tester) async {
      final store = _MemoryStore();
      final cache = _ChatFixtureCache();
      final app = _CachedApp(store: store, fixture: cache);
      final contacts = ContactsService(store: store);
      final display = MessageDisplayController(store: store);
      addTearDown(app.dispose);
      addTearDown(contacts.dispose);
      addTearDown(display.dispose);
      final unread = ChatSummary(guid: 'row', hasUnread: true, unreadCount: 3);
      Future<void> show(ChatSummary chat, String key) async {
        cache.rows = [chat];
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<AppController>.value(value: app),
              ChangeNotifierProvider<ContactsService>.value(value: contacts),
              ChangeNotifierProvider<MessageDisplayController>.value(
                value: display,
              ),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: ChatListScreen(key: ValueKey(key), onOpen: (_) {}),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await show(unread, 'unread');
      expect(
        tester
            .widget<Material>(find.byKey(const ValueKey('chat-row-chat:row')))
            .color,
        isNot(Colors.transparent),
      );
      await show(unread.copyWith(hasUnread: false), 'read');
      expect(
        tester
            .widget<Material>(find.byKey(const ValueKey('chat-row-chat:row')))
            .color,
        Colors.transparent,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'rejection locks records and ignores stale rejection from an older profile',
    () async {
      final store = _MemoryStore();
      final app = _PairingApp(store: store);
      addTearDown(app.dispose);
      addTearDown(() {
        MediaCache.instance.accessAllowed = true;
        TopBanner.blocked = false;
      });
      final profile = ConnectionProfile(
        baseUrl: 'https://relay.example',
        token: 'current-credential',
        deviceId: 'device',
      );
      await app.saveAndActivate(profile);
      final list = ChatListController(app);
      addTearDown(list.dispose);
      list.chats = [ChatSummary(guid: 'private-history')];
      app.rejectCredential(profile.copyWith(token: 'old-credential'));
      expect(app.tokenRejected.value, isFalse);
      app.connectionProblemConfirmed.value = true;
      app.rejectCredential(profile);
      expect(app.hasProfile, isFalse);
      expect(app.profile, isNull);
      expect(app.api, isNull);
      expect(app.tokenRejected.value, isTrue);
      expect(app.connectionProblemConfirmed.value, isFalse);
      expect(list.chats, isEmpty);
      expect(await app.cache.listChats(), isEmpty);
      expect(await app.cache.listMessages('private-history'), isEmpty);
      expect(MediaCache.instance.accessAllowed, isFalse);
      for (
        var i = 0;
        i < 10 && store._values[AppController.rejectedCredentialKey] != '1';
        i++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(store._values[AppController.rejectedCredentialKey], '1');
    },
  );

  testWidgets(
    'timeout dialog becomes the rejection dialog without duplicate errors',
    (tester) async {
      final app = _PairingApp(store: _MemoryStore());
      final profile = ConnectionProfile(
        baseUrl: 'https://relay.example',
        token: 'credential',
        deviceId: 'device',
      );
      await app.saveAndActivate(profile);
      addTearDown(app.dispose);
      addTearDown(() {
        MediaCache.instance.accessAllowed = true;
        TopBanner.blocked = false;
      });
      await tester.pumpWidget(
        ChangeNotifierProvider<AppController>.value(
          value: app,
          child: MaterialApp(
            home: const ConnectionNoticeHost(
              child: Scaffold(body: Text('screen')),
            ),
          ),
        ),
      );
      app.connectionProblemConfirmed.value = true;
      await tester.pumpAndSettle();
      final strings = MicaLocalizations.current;
      expect(
        find.text(strings.t('connection.cannotReachTitle')),
        findsOneWidget,
      );
      app.rejectCredential(profile);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.text(strings.t('connection.tokenRejectedTitle')),
        findsOneWidget,
      );
      expect(find.text(strings.t('connection.cannotReachTitle')), findsNothing);
      expect(find.text(strings.t('common.retry')), findsNothing);
      expect(find.text(strings.t('common.dismiss')), findsNothing);
      await tester.tap(find.text(strings.t('connection.pairAgain')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.text(strings.t('connection.tokenRejectedBody')),
        findsNothing,
      );
      expect(find.text(strings.t('connection.pairAgain')), findsNothing);
      expect(tester.getTopLeft(find.text('screen')).dy, 0);
      expect(
        find.text(strings.t('connection.serverUnavailable')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'failed storage preflight never redeems the single-use invitation',
    () async {
      final app = _PairingApp(store: _UnavailableStore());
      addTearDown(app.dispose);
      await expectLater(
        app.saveAndActivate(
          ConnectionProfile(
            baseUrl: 'https://relay.example',
            token: '',
            pairingCode: 'unused',
          ),
        ),
        throwsA(isA<CompatibilityStorageRequired>()),
      );
      expect(app.redemptions, 0);
      expect(app.profile, isNull);
    },
  );

  test(
    'retry after secure save failure reuses the redeemed device credential',
    () async {
      final store = _FailOnceStore();
      final app = _PairingApp(store: store);
      addTearDown(app.dispose);
      final invitation = ConnectionProfile(
        baseUrl: 'https://relay.example',
        token: 'invitation',
        pairingCode: 'invitation',
      );
      await expectLater(
        app.saveAndActivate(invitation),
        throwsA(isA<CredentialStorageException>()),
      );
      expect(app.profile, isNull);
      expect(app.redemptions, 1);
      await app.saveAndActivate(invitation);
      expect(app.redemptions, 1);
      expect(app.profile!.deviceId, 'test-device');
      expect(store._saved!.pairingCode, isNull);
      expect(store._saved!.token, 'test-device-credential');
    },
  );

  test('batch mute applies to every route in a merged conversation', () async {
    final controller = AppController(store: _MemoryStore());
    const routes = ['iMessage;+1', 'iMessage;email@example.com', 'SMS;+1'];

    expect(controller.areChatsMuted(routes), isFalse);

    await controller.setChatsMuted(routes, true);
    expect(controller.areChatsMuted(routes), isTrue);
    for (final route in routes) {
      expect(controller.isChatMuted(route), isTrue);
    }

    await controller.setChatsMuted(routes, false);
    expect(controller.areChatsMuted(routes), isFalse);
    for (final route in routes) {
      expect(controller.isChatMuted(route), isFalse);
    }
  });
}

class _FailOnceStore extends _MemoryStore {
  int attempts = 0;
  @override
  Future<void> saveProfile(ConnectionProfile profile) async {
    if (++attempts == 1) throw const CredentialStorageException();
    await super.saveProfile(profile);
  }
}

class _PairingApp extends AppController {
  @override
  bool get bootstrapped => true;
  _PairingApp({required super.store});
  int redemptions = 0;
  @override
  Future<ConnectionProfile> redeemPairingProfile(
    ConnectionProfile profile,
  ) async {
    redemptions++;
    return profile.copyWith(
      token: 'test-device-credential',
      deviceId: 'test-device',
      pairingCode: null,
    );
  }

  @override
  Future<bool> selectReachableCandidate({
    required String reason,
    ConnectionCandidateKind? skipKind,
  }) async => true;
}

class _ChatFixtureCache extends LocalCacheStore {
  List<ChatSummary> rows = [];
  final metadata = <String, String>{};
  Set<String> hidden = {};
  @override
  Future<void> applyReadPositions(Map<String, int> positions) async {}

  @override
  Future<void> applyUnreadMarks(Map<String, bool> marks) async {
    rows = rows
        .map(
          (row) => marks.containsKey(row.guid)
              ? row.copyWith(hasUnread: marks[row.guid], unreadCount: 0)
              : row,
        )
        .toList();
  }

  @override
  Future<String?> readMetadata(String key) async => metadata[key];
  @override
  Future<void> writeMetadata(String key, String value) async {
    metadata[key] = value;
  }

  @override
  Future<Set<String>> legacyHiddenChatGuids() async => {};
  @override
  Future<void> applyChatVisibility(Set<String> values) async {
    hidden = values;
  }

  @override
  Future<void> markChatsSeen(Iterable<String> guids, {int? upTo}) async {
    rows = rows
        .map(
          (row) => guids.contains(row.guid)
              ? row.copyWith(hasUnread: false, unreadCount: 0)
              : row,
        )
        .toList();
  }

  @override
  Future<Map<String, int>> readPositions(Iterable<String> routes) async => {
    for (final route in routes) route: 100,
  };
  @override
  Future<List<ChatSummary>> listChats({
    bool includeDebug = false,
    bool includeHidden = false,
  }) async => accessAllowed
      ? rows
            .where((row) => includeHidden || !hidden.contains(row.guid))
            .toList()
      : [];
}

class _CachedApp extends AppController {
  _CachedApp({required super.store, required this.fixture});
  final _ChatFixtureCache fixture;
  @override
  LocalCacheStore get cache => fixture;
}

class _UnavailableStore extends _MemoryStore {
  @override
  Future<void> prepareCredentialStorage({
    Future<bool> Function()? confirmCompatibility,
  }) async {
    throw const CompatibilityStorageRequired();
  }
}
