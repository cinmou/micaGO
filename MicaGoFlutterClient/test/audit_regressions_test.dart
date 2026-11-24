import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mica_go/core/app_controller.dart';
import 'package:mica_go/core/models/connection_profile.dart';
import 'package:mica_go/core/network/api_client.dart';
import 'package:mica_go/core/network/push_service.dart';
import 'package:mica_go/core/network/unified_push.dart';
import 'package:mica_go/core/network/websocket_client.dart';
import 'package:mica_go/core/storage/local_cache_store.dart';
import 'package:mica_go/core/storage/media_cache.dart';
import 'package:mica_go/core/storage/secure_store.dart';
import 'package:mica_go/core/ui/top_banner.dart';
import 'package:mica_go/features/chats/models/chat_summary.dart';
import 'package:mica_go/features/chats/models/message_model.dart';
import 'package:mica_go/features/chats/thread_controller.dart';
import 'package:mica_go/features/chats/voice_recorder.dart';

class _MemStore implements SecureStore {
  ConnectionProfile? saved;
  final Map<String, String> values = {};

  @override
  Future<bool> compatibilityStorageEnabled() async => false;
  @override
  Future<void> prepareCredentialStorage({
    Future<bool> Function()? confirmCompatibility,
  }) async {}
  @override
  Future<ConnectionProfile?> loadProfile() async => saved;
  @override
  Future<void> saveProfile(ConnectionProfile profile) async {
    saved = profile;
  }

  @override
  Future<void> clearProfile() async {
    saved = null;
  }

  @override
  Future<bool> contactsMatchingEnabled() async => false;
  @override
  Future<void> setContactsMatchingEnabled(bool enabled) async {}
  @override
  Future<String?> readValue(String key) async => values[key];
  @override
  Future<void> writeValue(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> deleteValue(String key) async {
    values.remove(key);
  }
}

class _MemCache extends LocalCacheStore {
  final Map<String, String> meta = {};
  final List<MessageModel> upserted = [];
  final List<String> confirmed = [];
  final List<String> pendingStates = [];

  @override
  Future<void> open() async {}
  @override
  Future<void> clearAll() async {
    meta.clear();
    upserted.clear();
    confirmed.clear();
    pendingStates.clear();
  }

  @override
  Future<String?> readMetadata(String key) async => meta[key];
  @override
  Future<void> writeMetadata(String key, String value) async {
    meta[key] = value;
  }

  @override
  Future<void> deleteMetadata(String key) async {
    meta.remove(key);
  }

  @override
  Future<Map<String, String>> readMetadataWithPrefix(String prefix) async => {
    for (final e in meta.entries)
      if (e.key.startsWith(prefix)) e.key: e.value,
  };

  @override
  Future<bool> hasMessage(String chatGuid, String guid) async => false;

  @override
  Future<void> upsertMessage(String chatGuid, MessageModel message) async {
    upserted.add(message);
  }

  @override
  Future<bool> bumpChatWithMessage(
    MessageModel message, {
    bool markUnread = false,
    bool seen = false,
  }) async => true;

  @override
  Future<void> addPending(String chatGuid, MessageModel message) async {}

  @override
  Future<void> confirmPending(
    String chatGuid,
    String tempId,
    MessageModel confirmedMsg,
  ) async {
    confirmed.add(tempId);
  }

  @override
  Future<void> setPendingState(String tempId, LocalSendState state) async {
    pendingStates.add('$tempId:${state.name}');
  }

  @override
  Future<Map<String, int>> readPositions(Iterable<String> guids) async => {
    for (final g in guids) g: 0,
  };

  @override
  Future<List<ChatSummary>> listChats({
    bool includeDebug = false,
    bool includeHidden = false,
  }) async => const [];

  @override
  Future<Set<String>> legacyHiddenChatGuids() async => {};
  @override
  Future<Set<String>> hiddenMessageGuids() async => {};
  @override
  Future<List<HiddenMessageRecord>> hiddenMessages() async => const [];
  @override
  Future<void> applyChatVisibility(Set<String> hidden) async {}
  @override
  Future<void> applyMessageVisibility(Set<String> hidden) async {}
  @override
  Future<void> applyReadPositions(Map<String, int> positions) async {}
  @override
  Future<void> applyUnreadMarks(Map<String, bool> marks) async {}

  @override
  Future<void> close() async {}
}

class _SessionTestApp extends AppController {
  _SessionTestApp({
    required super.store,
    required this.memCache,
    this.apiOverride,
  });

  final _MemCache memCache;
  ApiClient? apiOverride;

  @override
  LocalCacheStore get cache => memCache;

  @override
  ApiClient? get api => tokenRejected.value ? null : (apiOverride ?? super.api);

  @override
  Future<bool> selectReachableCandidate({
    required String reason,
    dynamic skipKind,
  }) async => false;

  @override
  void connectWebSocket() {}
}

class _RecordingWsApp extends _SessionTestApp {
  _RecordingWsApp({required super.store, required super.memCache});
  final _events = StreamController<WsEvent>.broadcast();

  @override
  WebSocketClient get ws => _FakeWs(_events.stream);

  void emitWs(WsEvent event) => _events.add(event);

  @override
  void dispose() {
    unawaited(_events.close());
    super.dispose();
  }
}

class _FakeWs extends WebSocketClient {
  _FakeWs(this._stream);
  final Stream<WsEvent> _stream;
  @override
  Stream<WsEvent> get events => _stream;
}

ConnectionProfile _profile(String id, String token) => ConnectionProfile(
  baseUrl: 'https://relay.example',
  token: token,
  deviceId: id,
  tlsFingerprint: 'a' * 64,
  publicBaseUrl: 'https://relay.example',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    MediaCache.instance.accessAllowed = true;
    TopBanner.blocked = false;
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'signOut resets in-memory syncCursor, clears profile immediately, and stops stale refreshServerUrls from resurrecting profile',
    () async {
      final store = _MemStore()..saved = _profile('dev-1', 'tok-1');
      final memCache = _MemCache();
      final seenCursors = <String?>[];
      final urlGate = Completer<void>();
      final client = ApiClient(
        baseUrl: 'https://relay.example',
        token: 'tok-1',
        httpClient: MockClient((request) async {
          if (request.url.path == '/api/messages/delta') {
            seenCursors.add(request.url.queryParameters['since']);
            return http.Response(
              jsonEncode({
                'messages': [],
                'chatGuids': [],
                'cursor': 42,
                'hasMore': false,
              }),
              200,
            );
          }
          if (request.url.path == '/api/server/urls') {
            await urlGate.future;
            return http.Response(
              jsonEncode({
                'connectionRevision': 'rev-2',
                'lan': [],
                'public': {
                  'enabled': true,
                  'baseUrl': 'https://relay.example',
                  'wsUrl': 'wss://relay.example/ws',
                },
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );
      addTearDown(client.close);
      final app = _SessionTestApp(
        store: store,
        memCache: memCache,
        apiOverride: client,
      );
      addTearDown(app.dispose);
      await app.bootstrap();
      expect(app.hasProfile, isTrue);

      await app.runDeltaSync(reason: 'first');
      expect(seenCursors, [null]);
      await app.runDeltaSync(reason: 'second');
      expect(seenCursors, [null, '42']);

      final slowRefresh = app.refreshServerUrls();
      final signOutFuture = app.signOut();
      // Immediately cleared synchronously before awaits finish.
      expect(app.hasProfile, isFalse);
      await signOutFuture;
      expect(store.saved, isNull);

      urlGate.complete();
      await slowRefresh;
      expect(store.saved, isNull);
      expect(app.hasProfile, isFalse);

      // Re-pairing in the same process must not reuse the old in-memory cursor 42.
      await app.saveAndActivate(_profile('dev-2', 'tok-2'));
      await app.runDeltaSync(reason: 'after-repair');
      expect(seenCursors, [null, '42', null]);
    },
  );

  test(
    'in-flight runDeltaSync does not write cache or advance cursor after rejectCredential',
    () async {
      final store = _MemStore()..saved = _profile('dev-1', 'tok-1');
      final memCache = _MemCache();
      final deltaGate = Completer<void>();
      final client = ApiClient(
        baseUrl: 'https://relay.example',
        token: 'tok-1',
        httpClient: MockClient((request) async {
          await deltaGate.future;
          return http.Response(
            jsonEncode({
              'messages': [
                {
                  'guid': 'm-after-reject',
                  'chatGuid': 'iMessage;-;+15550001',
                  'text': 'stale',
                  'dateCreated': 1000,
                },
              ],
              'chatGuids': ['iMessage;-;+15550001'],
              'cursor': 99,
              'hasMore': false,
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);
      final app = _SessionTestApp(
        store: store,
        memCache: memCache,
        apiOverride: client,
      );
      addTearDown(app.dispose);
      await app.bootstrap();

      final syncing = app.runDeltaSync(reason: 'inflight');
      app.rejectCredential(app.profile!);
      deltaGate.complete();
      await syncing;

      expect(memCache.upserted, isEmpty);
      expect(memCache.meta['sync_cursor'], isNull);
    },
  );

  test(
    'ThreadController.send does not write to cache after signOut or rejection',
    () async {
      final store = _MemStore()..saved = _profile('dev-1', 'tok-1');
      final memCache = _MemCache();
      final sendGate = Completer<void>();
      final client = ApiClient(
        baseUrl: 'https://relay.example',
        token: 'tok-1',
        httpClient: MockClient((request) async {
          await sendGate.future;
          return http.Response(
            jsonEncode({
              'guid': 'server-msg-1',
              'chatGuid': 'iMessage;-;+15550001',
              'text': 'hello',
              'isFromMe': true,
              'dateCreated': 1000,
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);
      final app = _SessionTestApp(
        store: store,
        memCache: memCache,
        apiOverride: client,
      );
      addTearDown(app.dispose);
      await app.bootstrap();

      final thread = ThreadController(
        app: app,
        chatGuid: 'iMessage;-;+15550001',
      );
      addTearDown(thread.dispose);

      final sending = thread.send('hello');
      await Future<void>.delayed(Duration.zero);
      app.rejectCredential(app.profile!);
      sendGate.complete();
      await sending;

      expect(memCache.confirmed, isEmpty);
      expect(memCache.pendingStates, isEmpty);
    },
  );

  test(
    'AppController activeChatGuids respects owner on clearActiveChatGuids',
    () {
      final app = AppController(store: _MemStore());
      addTearDown(app.dispose);
      final ownerA = Object();
      final ownerB = Object();

      app.setActiveChatGuids(['chat-a'], owner: ownerA);
      expect(app.isChatActive('chat-a'), isTrue);

      app.setActiveChatGuids(['chat-b'], owner: ownerB);
      expect(app.isChatActive('chat-a'), isFalse);
      expect(app.isChatActive('chat-b'), isTrue);

      // Delayed dispose from ownerA must not clear ownerB's active chat.
      app.clearActiveChatGuids(owner: ownerA);
      expect(app.isChatActive('chat-b'), isTrue);

      app.clearActiveChatGuids(owner: ownerB);
      expect(app.isChatActive('chat-b'), isFalse);
    },
  );

  test(
    'Android background keep-alive notification re-checks credential rejection after await',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final store = _MemStore()..saved = _profile('dev-1', 'tok-1');
      final memCache = _MemCache();
      final app = _RecordingWsApp(store: store, memCache: memCache);
      addTearDown(app.dispose);
      await app.bootstrap();
      await app.setKeepAliveEnabled(true);
      app.setForeground(false);

      final avatarGate = Completer<Uint8List?>();
      var shown = 0;
      app.contactAvatarResolver = (_) => avatarGate.future;
      app.showLocalNotification =
          ({
            required String? chatGuid,
            required String messageGuid,
            required String senderName,
            required String conversationTitle,
            String? senderKey,
            String? body,
            String? avatarFilePath,
            String? conversationAvatarFilePath,
            bool isGroup = false,
            int? timestampMs,
          }) async {
            shown++;
          };

      app.emitWs(
        const WsEvent('message:new', {
          'chatGuid': 'iMessage;-;+15550001',
          'guid': 'msg-1',
          'text': 'secret',
          'handleId': '+15550001',
          'isFromMe': false,
          'dateCreated': 2000,
        }),
      );
      await Future<void>.delayed(Duration.zero);
      app.rejectCredential(app.profile!);
      avatarGate.complete(null);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(shown, 0);
    },
  );

  test('PushService.dispose clears UnifiedPushBridge.restart', () {
    final app = AppController(store: _MemStore());
    addTearDown(app.dispose);
    final push = PushService(app);
    UnifiedPushBridge.restart = push.restart;
    expect(UnifiedPushBridge.restart, isNotNull);
    push.dispose();
    expect(UnifiedPushBridge.restart, isNull);
  });

  test('VoiceRecorder cancel removes leftover temp recording file', () async {
    const channel = MethodChannel('com.llfbandit.record/messages');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? startedPath;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'hasPermission':
          return true;
        case 'start':
          startedPath = (call.arguments as Map)['path'] as String?;
          if (startedPath != null) {
            await File(startedPath!).writeAsBytes([1, 2, 3]);
          }
          return null;
        case 'cancel':
        case 'dispose':
          return null;
        default:
          return null;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final recorder = VoiceRecorder();
    expect(await recorder.start(), isTrue);
    expect(startedPath, isNotNull);
    expect(await File(startedPath!).exists(), isTrue);

    await recorder.cancel();
    expect(await File(startedPath!).exists(), isFalse);
    recorder.dispose();
  });
}
