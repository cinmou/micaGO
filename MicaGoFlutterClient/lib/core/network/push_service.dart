import 'package:micago_conversations/micago_conversations.dart';
import 'dart:async';
import 'package:async/async.dart';
import '../storage/local_cache_store.dart';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../app_controller.dart';
import '../l10n/app_localizations.dart';
import '../../features/chats/models/message_model.dart';
import '../storage/secure_store.dart';
import 'api_client.dart';
import 'notification_contact_cache.dart';
import 'notification_display.dart';
import 'push_logic.dart';

/// Storage key for the user-owned Firebase client options. C28: MicaGo bakes no
/// google-services.json, so the FCM **background isolate** (a fresh process when
/// the app was killed) has no default Firebase app to attach to. We persist the
/// runtime options here when the foreground initializes Firebase, and the
/// background handler reads them to `Firebase.initializeApp(options:)` — without
/// this, the killed-app background handler can't init Firebase and shows nothing.
const String fcmOptionsStorageKey = 'micago.fcm_options.v1';

void registerMicaGoFirebaseBackgroundHandler() {
  try {
    FirebaseMessaging.onBackgroundMessage(micaGoFirebaseBackgroundHandler);
  } catch (e) {
    debugPrint('PushService: background handler registration deferred ($e)');
  }
}

/// Pure: the minimal Firebase options map persisted for the background isolate.
Map<String, String> fcmOptionsStorageMap(Map<String, dynamic> cfg) => {
  'apiKey': (cfg['apiKey'] ?? '') as String,
  'appId': (cfg['appId'] ?? '') as String,
  'messagingSenderId': (cfg['messagingSenderId'] ?? '') as String,
  'projectId': (cfg['projectId'] ?? '') as String,
  'storageBucket': (cfg['storageBucket'] ?? '') as String,
};

/// Pure: build [FirebaseOptions] from a persisted/config map. An empty
/// storageBucket maps to null (the field is optional).
FirebaseOptions firebaseOptionsFromMap(Map<String, dynamic> m) {
  final bucket = (m['storageBucket'] as String?)?.trim() ?? '';
  return FirebaseOptions(
    apiKey: (m['apiKey'] ?? '') as String,
    appId: (m['appId'] ?? '') as String,
    messagingSenderId: (m['messagingSenderId'] ?? '') as String,
    projectId: (m['projectId'] ?? '') as String,
    storageBucket: bucket.isEmpty ? null : bucket,
  );
}

/// C22 — BlueBubbles-style FCM wake layered on top of WebSocket + delta sync.
///
/// Faithful to BlueBubbles' model (`cloud_messaging_service.dart`,
/// `method_channel_service.dart` `new-message` handler, `fcmService/index.ts`):
/// the push is a thin **wake/awareness** signal — the real message data always
/// arrives over the socket (foreground) or the delta cursor (catch-up), never
/// from the push body. Firebase is **optional**: when the server has no
/// user-owned config the whole service no-ops and the app stays on WS + delta.
///
/// Dedup rule (BlueBubbles): if the app is alive and the socket is connected,
/// the socket already handled the event, so the FCM message is ignored.
class PushService {
  PushService(this.app);

  final AppController app;

  bool _disposed = false;
  final _startup = AsyncCache<void>.ephemeral();
  StreamSubscription<String>? _tokenSubscription;
  StreamSubscription<RemoteMessage>? _messageSubscription;
  StreamSubscription<RemoteMessage>? _tapSubscription;
  bool available = false;
  bool _localReady = false;
  String? token;

  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  /// Idempotent start. Safe to call on every (re)connect. It always brings up
  /// local notifications first (the keep-alive path needs them and does NOT need
  /// Firebase), then does the FCM-specific work only when Firebase is configured.
  Future<void> start() => _startup.fetch(_start);

  Future<void> _start() async {
    if (_disposed || !app.hasProfile) return;
    // 0) Local notifications + the keep-alive shower — independent of Firebase,
    //    so background WebSocket/delta messages can notify even with no FCM.
    await _ensureLocalNotifications();
    if (_disposed || !app.hasProfile) return;

    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    if (available) {
      // FCM already running: just make sure the latest token is registered.
      await _registerToken();
      return;
    }
    final api = app.api;
    if (api == null) return;

    // 1) Pull the user-owned Firebase client config from the server.
    final Map<String, dynamic> cfg;
    try {
      cfg = await api.fetchFcmClientConfig();
    } on ApiException catch (error) {
      debugPrint(
        'PushService: FCM config request failed: ${error.code} (${error.statusCode})',
      );
      return;
    }
    if (cfg['configured'] != true) {
      // Firebase not set up → stay on WebSocket + delta sync (+ keep-alive local
      // notifications when enabled). Fully graceful.
      debugPrint(
        'PushService: FCM client config not available; will retry later',
      );
      return;
    }

    // 2) Initialize Firebase at runtime from that config (no google-services
    //    baked into the APK — BlueBubbles' user-owned-project model). Persist the
    //    options FIRST so the background isolate (a fresh process after a kill)
    //    can re-init Firebase the same way — otherwise killed-app pushes can't
    //    show a notification.
    await _persistOptions(cfg);
    try {
      await Firebase.initializeApp(options: firebaseOptionsFromMap(cfg));
    } catch (e) {
      // Already-initialized is fine; any other failure → degrade to WS/delta.
      if (e is! FirebaseException || e.code != 'duplicate-app') {
        debugPrint('PushService: Firebase init failed ($e); using WS + delta');
        return;
      }
    }

    // 3) Permission + token.
    final messaging = FirebaseMessaging.instance;
    try {
      await messaging.requestPermission();
      token = await messaging.getToken();
    } catch (e) {
      debugPrint('PushService: token fetch failed ($e); using WS + delta');
      return;
    }
    if (token == null || token!.isEmpty) {
      debugPrint(
        'PushService: Firebase returned no FCM token; will retry later',
      );
      return;
    }
    debugPrint('PushService: FCM token ready (${token!.length} chars)');

    if (_disposed || !app.hasProfile) return;
    available = true;

    // 4) Register the token + react to refreshes.
    await _registerToken();
    if (_disposed || !app.hasProfile) return;
    _tokenSubscription = messaging.onTokenRefresh.listen((t) {
      if (_disposed || !app.hasProfile) return;
      token = t;
      unawaited(_registerToken());
    });

    // 5) Handlers (foreground / tap / terminated-launch) + the background isolate
    //    handler. The background registration persists natively, so a later
    //    killed-app delivery still spawns the isolate and runs our handler.
    registerMicaGoFirebaseBackgroundHandler();
    _messageSubscription = FirebaseMessaging.onMessage.listen(
      _onForegroundMessage,
    );
    _tapSubscription = FirebaseMessaging.onMessageOpenedApp.listen(
      _onNotificationTap,
    );
    final initial = await messaging.getInitialMessage();
    if (initial != null) _onNotificationTap(initial);
  }

  void dispose() {
    _disposed = true;
    unawaited(_tokenSubscription?.cancel());
    unawaited(_messageSubscription?.cancel());
    unawaited(_tapSubscription?.cancel());
    app.showLocalNotification = null;
    app.clearChatNotification = null;
    app.clearReadNotification = null;
  }

  Future<void> _persistOptions(Map<String, dynamic> cfg) async {
    try {
      await app.store.writeValue(
        fcmOptionsStorageKey,
        jsonEncode(fcmOptionsStorageMap(cfg)),
      );
    } catch (_) {
      // Foreground Firebase can continue; a fresh background engine requires
      // these persisted options and skips initialization if they are missing.
    }
  }

  Future<void> _registerToken() async {
    await app.updatePushRegistration(
      provider: 'fcm',
      token: token,
      enabled: token != null && token!.isNotEmpty,
    );
  }

  // Foreground: the socket is usually live and already delivered the row, so we
  // follow BlueBubbles and DON'T raise a system notification (no spam). If the
  // socket happens to be down, run a delta catch-up so the open thread/list
  // still update — GUID dedup prevents duplicate bubbles.
  void _onForegroundMessage(RemoteMessage message) {
    if (_disposed || !app.hasProfile) return;
    if (!pushShouldCatchUp(realtimeConnected: app.isRealtimeConnected)) {
      return; // socket already handled it (BlueBubbles dedup)
    }
    app.noteNotificationSource('FCM');
    unawaited(app.runDeltaSync(reason: 'fcm-foreground'));
  }

  // Tap (from background or terminated): delta-sync FIRST so we don't show stale
  // content, then ask the shell to open the conversation.
  void _onNotificationTap(RemoteMessage message) {
    if (_disposed || !app.hasProfile) return;
    app.noteNotificationSource('FCM');
    unawaited(app.runDeltaSync(reason: 'fcm-tap'));
    final chatGuid = pushChatGuid(message.data);
    if (chatGuid != null) app.requestOpenChat(chatGuid);
  }

  /// Brings up local notifications exactly once and wires the keep-alive
  /// local-notification path on [AppController]. This has NO Firebase dependency,
  /// so it runs even when FCM is not configured.
  Future<void> _ensureLocalNotifications() async {
    if (_localReady) return;
    await _initLocalNotifications();
    if (_disposed || !app.hasProfile) return;
    _localReady = true;
    // The keep-alive path (in AppController) shows local notifications through
    // the same initialized plugin, so FCM + keep-alive dedupe by notification id.
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
        }) => _disposed || !app.hasProfile || app.isChatMuted(chatGuid ?? '')
        ? Future<void>.value()
        : showMessageNotification(
            _local,
            chatGuid: chatGuid,
            deviceId: app.profile?.deviceId,
            replyLabel: MicaLocalizations.current.t('notif.reply'),
            replyHint: MicaLocalizations.current.t('common.message'),
            readLabel: MicaLocalizations.current.t('notif.markRead'),
            messageGuid: messageGuid,
            senderName: senderName,
            senderKey: senderKey,
            conversationTitle: conversationTitle,
            body: body,
            avatarFilePath: avatarFilePath,
            conversationAvatarFilePath: conversationAvatarFilePath,
            isGroup: isGroup,
            timestampMs: timestampMs,
          );
    // Opening a chat clears its stacked conversation notification.
    app.clearChatNotification = (chatGuid) =>
        cancelChatNotification(_local, chatGuid);
    app.clearReadNotification = (chatGuid, through) =>
        cancelNotificationThrough(
          notificationPayload(
            chatGuid,
            app.profile?.deviceId ?? '',
            readThrough: through,
          ),
        );
    await refreshNotificationPermission();
  }

  /// Queries whether the OS currently allows notifications (Android 13+
  /// POST_NOTIFICATIONS) and records it on [AppController] for diagnostics.
  Future<void> refreshNotificationPermission() async {
    app.noteNotificationPermission(await systemNotificationsEnabled());
  }

  Future<void> _initLocalNotifications() async {
    const android = AndroidInitializationSettings(
      '@drawable/$androidNotificationSmallIcon',
    );
    await _local.initialize(
      const InitializationSettings(android: android),
      onDidReceiveNotificationResponse: (resp) {
        if (resp.actionId == notificationReplyActionId ||
            resp.actionId == notificationReadActionId) {
          unawaited(handleNotificationAction(resp, app: app));
          return;
        }
        _openNotification(resp.payload);
      },
      onDidReceiveBackgroundNotificationResponse:
          notificationBackgroundResponse,
    );
    final launch = await _local.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true) {
      final response = launch?.notificationResponse;
      if (response?.actionId != notificationReplyActionId &&
          response?.actionId != notificationReadActionId) {
        _openNotification(response?.payload);
      }
    }
    await _local
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(messageNotificationChannel);
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await AndroidConversations.listen(_openNotification);
      } catch (_) {}
    }
  }

  void _openNotification(String? payload) {
    if (_disposed || !app.hasProfile) return;
    final target = NotificationTarget.parse(payload);
    if (target?.deviceId != null && target!.deviceId != app.profile?.deviceId) {
      return;
    }
    final guid = target?.chatGuid;
    if (guid?.isNotEmpty == true) app.requestOpenChat(guid!);
  }
}

/// Top-level background handler (runs in its own isolate when the app is
/// backgrounded/killed). It only shows a local notification from the lightweight
/// push data. The server sends data-only FCM messages so Android always routes
/// them here instead of showing a system-managed notification. The actual message
/// fetch still happens via delta sync when the app next opens/resumes (the
/// existing `onResume` → `catchUp` path), exactly the BlueBubbles
/// "push wakes, sync fetches" model. Kept dependency-free of the running app so
/// it works without a live AppController.
@pragma('vm:entry-point')
Future<void> micaGoFirebaseBackgroundHandler(RemoteMessage message) async {
  if (!await ensureBackgroundFirebase()) {
    // Firebase couldn't init here; skip the local notification. The missed
    // message is still delivered by delta catch-up on the next resume.
    return;
  }
  await showPushNotification(message);
}

/// Initializes Firebase inside the FCM background isolate. MicaGo bakes no
/// google-services.json / GoogleService-Info.plist, so a killed-app push runs in
/// a fresh process with NO default Firebase app. Only initialize from persisted
/// runtime options; otherwise gracefully skip Firebase instead of asking native
/// Firebase to load a missing default config.
@pragma('vm:entry-point')
Future<bool> ensureBackgroundFirebase() async {
  if (Firebase.apps.isNotEmpty) return true;
  try {
    final raw = await SecureStore().readValue(fcmOptionsStorageKey);
    if (raw != null && raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        await Firebase.initializeApp(options: firebaseOptionsFromMap(decoded));
        return true;
      }
    }
  } catch (_) {
    return false;
  }
  return false;
}

/// C32: shows the FCM (background isolate) notification as a native MessagingStyle
/// conversation, stacked per chat. Deduped by message guid against the keep-alive
/// path via the shared per-chat buffer + notification id. The background isolate
/// cannot read contacts, but it can still use bundled app resources for known
/// local chats such as the offline test contact.
final _notificationCache = LocalCacheStore();

Future<void> showPushNotification(RemoteMessage message) async {
  final store = SecureStore();
  if (await store.readValue(AppController.rejectedCredentialKey) == '1') return;
  final profile = await store.loadProfile();
  if (profile == null) return;
  final data = message.data;
  // Single source of truth for "is there anything to show" (test pushes and
  // preview-disabled empty pushes are skipped) — shared with the pure logic test.
  if (!pushShouldNotify(data)) return;
  final chatGuid = data['chatGuid'] as String?;
  if (chatGuid != null) {
    if ((await _notificationCache.effectiveHiddenChatGuids()).contains(
      chatGuid,
    )) {
      return;
    }
  }

  if (chatGuid != null) {
    final guid = data['messageGuid'] ?? data['guid'];
    final hidden = await _notificationCache.hiddenMessageGuids();
    if (guid != null &&
        (hidden.contains('$chatGuid\u001f$guid') || hidden.contains(guid))) {
      return;
    }
    final at = int.tryParse('${data['dateCreated'] ?? ''}');
    if (at != null && at > 0) {
      final positions = await _notificationCache.readPositions([chatGuid]);
      if (at <= (positions[chatGuid] ?? 0)) return;
    }
  }

  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings(
        '@drawable/$androidNotificationSmallIcon',
      ),
    ),
    onDidReceiveBackgroundNotificationResponse: notificationBackgroundResponse,
  );
  await plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(messageNotificationChannel);
  // C31/C32: group conversations use the group as conversation title and the
  // message author as Person. The FCM isolate cannot read contacts directly —
  // C60: it reads the handle → {contact name, avatar file} cache the main
  // isolate persists, so pushes show the real name + photo; server-provided
  // names/handles remain the fallback for uncached handles / older servers.
  final cachedContact = await lookupNotificationContact(
    data['handle'] as String?,
  );
  final cachedName = cachedContact?.name?.trim() ?? '';
  final sender = cachedName.isNotEmpty
      ? cachedName
      : notificationSenderName(data);
  final isGroup = notificationIsGroup(data);
  // 1:1 chats: the conversation IS the contact, so the resolved name titles the
  // notification too. Groups keep the server-provided group title.
  final conversationTitle = isGroup
      ? notificationConversationTitle(data)
      : sender;
  final testAvatar = isTestContactPush(data) ? androidTestContactAvatar : null;
  await showMessageNotification(
    plugin,
    chatGuid: chatGuid,
    deviceId: profile.deviceId,
    messageGuid: (data['messageGuid'] as String?) ?? '',
    senderName: sender,
    senderKey: data['handle'] as String? ?? sender,
    conversationTitle: conversationTitle,
    body: notificationBody(data),
    avatarFilePath: cachedContact?.avatarPath,
    conversationAvatarFilePath: isGroup ? null : cachedContact?.avatarPath,
    avatarDrawableResource: testAvatar,
    conversationAvatarDrawableResource: testAvatar,
    isGroup: isGroup,
    timestampMs: notificationTimestampMs(data),
  );
}

/// C30: top-level handler for a notification action triggered while the app is
/// backgrounded/killed (runs in a background isolate). Handles the inline reply
/// by sending it to the chat; a plain tap is routed by app launch instead.
@pragma('vm:entry-point')
Future<void> notificationBackgroundResponse(
  NotificationResponse response,
) async {
  await handleNotificationAction(response);
}

Future<void> handleNotificationAction(
  NotificationResponse response, {
  AppController? app,
}) async {
  final payload = response.payload;
  if (payload == null) return;
  if (response.actionId == notificationReplyActionId) {
    final text = cleanReplyText(response.input);
    if (text != null) {
      final result = await handleNotificationReply(payload, text, app: app);
      app?.noteReplyResult(result);
    }
  } else if (response.actionId == notificationReadActionId) {
    final result = await markNotificationRead(payload, app: app);
    if (result == 'read saved') {
      await cancelNotificationThrough(payload);
    }
    // Failed/offline actions retain the original notification for retry.
  }
}

/// C30/C31: sends an inline-reply message to [chatGuid] using the persisted
/// connection profile (no live AppController needed, so it works from the
/// background isolate). Reuses the existing bearer token + send API; no new deps.
/// Returns a short, redaction-safe result string (used for diagnostics when the
/// app is alive); failures are reported, not thrown — the user can reopen and
/// resend.
@pragma('vm:entry-point')
Future<String> handleNotificationReply(
  String payload,
  String text, {
  AppController? app,
}) async {
  final result = await sendNotificationReply(payload, text, app: app);
  final guid = NotificationTarget.parse(payload)?.chatGuid;
  if (guid == null) return result;
  final plugin = FlutterLocalNotificationsPlugin();
  try {
    if (app == null) {
      await plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings(
            '@drawable/$androidNotificationSmallIcon',
          ),
        ),
        onDidReceiveBackgroundNotificationResponse:
            notificationBackgroundResponse,
      );
    }
    if (result == 'reply sent') {
      await cancelNotificationThrough(payload);
    } else {
      final message = result == 'reply pending'
          ? 'Delivery is awaiting confirmation. Open micaGO to check before resending.'
          : result == 'reply rejected'
          ? 'Device credential rejected. Open micaGO to pair again.'
          : 'Reply could not be sent. Open micaGO to send your message.';
      await plugin.show(
        notificationIdForMessage('reply-status:$guid'),
        'micaGO',
        message,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            messageChannelId,
            messageChannelName,
            icon: androidNotificationSmallIcon,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
        ),
        payload: payload,
      );
    }
  } catch (_) {}
  return result;
}

@pragma('vm:entry-point')
Future<String> sendNotificationReply(
  String payload,
  String text, {
  AppController? app,
}) async {
  if (cleanReplyText(text) == null) return 'reply failed';
  return _withNotificationSession(
    NotificationTarget.parse(payload),
    app: app,
    action: (api, chatGuid) async {
      await api.sendText(
        chatGuid: chatGuid,
        tempGuid: 'reply-${DateTime.now().microsecondsSinceEpoch}',
        message: text.trim(),
      );
      if (app != null) {
        unawaited(app.runDeltaSync(reason: 'notification-reply'));
      }
    },
    kind: 'reply',
  );
}

/// Uses the notification's cutoff, never the cache's newer chat preview.
Future<String> markNotificationRead(
  String payload, {
  AppController? app,
}) async {
  final target = NotificationTarget.parse(payload);
  final through = target?.readThrough;
  if (through == null) return 'read failed';
  return _withNotificationSession(
    target,
    app: app,
    kind: 'read',
    action: (api, chatGuid) async {
      final snapshot = await api.getReadState();
      final rows = snapshot['data'] as List;
      final row = rows
          .cast<Map<String, dynamic>>()
          .where((r) => r['chatGuid'] == chatGuid)
          .firstOrNull;
      final change = <String, dynamic>{
        'chatGuid': chatGuid,
        'readThrough': through,
      };
      if (row == null || (row['readThrough'] as num).toInt() <= through) {
        change.addAll({
          'markedUnread': false,
          'baseUnreadRevision': row?['unreadRevision'] ?? 0,
        });
      }
      final reply = await api.patchReadState({
        'serverId': snapshot['serverId'],
        'changes': [change],
      });
      final acknowledged = (reply['data'] as List)
          .cast<Map<String, dynamic>>()
          .any(
            (r) =>
                r['chatGuid'] == chatGuid &&
                (r['readThrough'] as num).toInt() >= through &&
                (!change.containsKey('markedUnread') ||
                    r['markedUnread'] == false),
          );
      if (reply['serverId'] != snapshot['serverId'] || !acknowledged) {
        throw StateError('Read position was not acknowledged');
      }
      final cache = app?.cache ?? _notificationCache;
      if (app != null && !identical(app.api, api)) {
        throw StateError('Connection changed');
      }
      await cache.applyReadPositions({chatGuid: through});
      final acknowledgedRow = (reply['data'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((r) => r['chatGuid'] == chatGuid);
      if (acknowledgedRow['markedUnread'] == false) {
        await cache.applyUnreadMarks({chatGuid: false});
      }
      if (app != null) {
        await app.readState.sync();
        unawaited(app.runDeltaSync(reason: 'notification-read'));
      }
    },
  );
}

Future<String> _withNotificationSession(
  NotificationTarget? target, {
  AppController? app,
  required String kind,
  required Future<void> Function(ApiClient, String) action,
}) async {
  final chatGuid = target?.chatGuid;
  final deviceId = target?.deviceId;
  if (chatGuid == null ||
      chatGuid.isEmpty ||
      deviceId == null ||
      deviceId.isEmpty) {
    return '$kind failed';
  }
  final store = app?.store ?? SecureStore();
  ApiClient? backgroundApi;
  try {
    if (await store.readValue(AppController.rejectedCredentialKey) == '1') {
      return '$kind rejected';
    }
    final profile = app == null ? await store.loadProfile() : app.profile;
    if (profile == null || !profile.isComplete) return '$kind rejected';
    if (profile.deviceId != deviceId) return '$kind failed';
    final api =
        app?.api ??
        (backgroundApi = ApiClient(
          baseUrl: profile.effectiveBaseUrl,
          token: profile.token,
          tlsFingerprint: profile.pinFor(profile.effectiveBaseUrl),
        ));
    await action(api, chatGuid);
    return kind == 'reply' ? 'reply sent' : 'read saved';
  } on ApiException catch (e) {
    if (e.code == 'unauthorized') {
      // Foreground credential rejection belongs to the verified API session.
      // A background action may use an old saved route; it cannot revoke pairing.
      return '$kind rejected';
    }
    return kind == 'reply' &&
            (e.sendState == LocalSendState.pending ||
                e.sendState == LocalSendState.sentUnconfirmed)
        ? 'reply pending'
        : '$kind failed';
  } catch (_) {
    return '$kind failed';
  } finally {
    backgroundApi?.close();
  }
}
