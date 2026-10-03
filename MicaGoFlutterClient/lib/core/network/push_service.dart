import 'dart:async';
import 'package:async/async.dart';
import '../storage/local_cache_store.dart';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../app_controller.dart';
import '../models/connection_profile.dart';
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
    final cfg = await api.fetchFcmClientConfig();
    if (cfg == null || cfg['configured'] != true) {
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
  }

  Future<void> _persistOptions(Map<String, dynamic> cfg) async {
    try {
      await app.store.writeValue(
        fcmOptionsStorageKey,
        jsonEncode(fcmOptionsStorageMap(cfg)),
      );
    } catch (_) {
      // Best-effort; the foreground init still proceeds. The background isolate
      // will fall back to a default-app init.
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
    await refreshNotificationPermission();
  }

  /// Queries whether the OS currently allows notifications (Android 13+
  /// POST_NOTIFICATIONS) and records it on [AppController] for diagnostics.
  Future<void> refreshNotificationPermission() async {
    app.noteNotificationPermission(await systemNotificationsEnabled());
  }

  /// Asks for the Android 13+ POST_NOTIFICATIONS permission (no-op below 13 or
  /// when already granted). Returns the resulting grant state.
  Future<bool?> requestNotificationPermission() async {
    final granted = await requestSystemNotificationPermission();
    app.noteNotificationPermission(granted);
    return granted;
  }

  Future<void> _initLocalNotifications() async {
    const android = AndroidInitializationSettings(
      '@drawable/$androidNotificationSmallIcon',
    );
    await _local.initialize(
      const InitializationSettings(android: android),
      onDidReceiveNotificationResponse: (resp) {
        // Inline reply (app alive): send it; otherwise a plain tap opens the chat.
        if (resp.actionId == notificationReplyActionId) {
          final text = cleanReplyText(resp.input);
          final guid = notificationChatFromPayload(resp.payload);
          if (text != null && guid != null && guid.isNotEmpty) {
            unawaited(
              handleNotificationReply(
                resp.payload!,
                text,
                app: app,
              ).then(app.noteReplyResult),
            );
          }
          return;
        }
        final guid = notificationChatFromPayload(resp.payload);
        if (guid != null && guid.isNotEmpty) app.requestOpenChat(guid);
      },
      onDidReceiveBackgroundNotificationResponse:
          notificationBackgroundResponse,
    );
    final launch = await _local.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true) {
      final response = launch?.notificationResponse;
      if (response?.actionId != notificationReplyActionId) {
        final guid = notificationChatFromPayload(response?.payload);
        if (guid != null) app.requestOpenChat(guid);
      }
    }
    await _local
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(messageNotificationChannel);
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
void notificationBackgroundResponse(NotificationResponse response) {
  if (response.actionId != notificationReplyActionId) return;
  final text = cleanReplyText(response.input);
  final payload = response.payload;
  if (text == null || payload == null) return;
  handleNotificationReply(payload, text).ignore();
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
  final guid = notificationChatFromPayload(payload);
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
      await cancelChatNotification(plugin, guid);
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
  final chatGuid = notificationChatFromPayload(payload);
  final deviceId = notificationDeviceFromPayload(payload);
  if (cleanReplyText(text) == null || chatGuid == null || deviceId == null) {
    return 'reply failed';
  }
  final store = app?.store ?? SecureStore();
  ApiClient? backgroundApi;
  ConnectionProfile? issuedProfile;
  try {
    if (await store.readValue(AppController.rejectedCredentialKey) == '1') {
      return 'reply rejected';
    }
    final profile = app?.profile ?? await store.loadProfile();
    if (profile == null || !profile.isComplete) return 'reply rejected';
    if (profile.deviceId != deviceId) return 'reply failed';
    issuedProfile = profile;
    final api =
        app?.api ??
        (backgroundApi = ApiClient(
          baseUrl: profile.effectiveBaseUrl,
          token: profile.token,
          tlsFingerprint: profile.pinFor(profile.effectiveBaseUrl),
        ));
    await api.sendText(
      chatGuid: chatGuid,
      tempGuid: 'reply-${DateTime.now().microsecondsSinceEpoch}',
      message: text.trim(),
    );
    if (app != null) unawaited(app.runDeltaSync(reason: 'notification-reply'));
    return 'reply sent';
  } on ApiException catch (e) {
    if (e.statusCode == 401) {
      if (app != null && issuedProfile != null) {
        app.rejectCredential(issuedProfile);
      } else {
        try {
          final current = await store.loadProfile();
          if (current?.deviceId == deviceId) {
            await store.writeValue(AppController.rejectedCredentialKey, '1');
            await store.clearProfile();
          }
        } catch (_) {
          /* Retry terminal cleanup when the app resumes. */
        }
      }
      return 'reply rejected';
    }
    return e.sendState == LocalSendState.pending ||
            e.sendState == LocalSendState.sentUnconfirmed
        ? 'reply pending'
        : 'reply failed';
  } catch (_) {
    return 'reply failed';
  } finally {
    backgroundApi?.close();
  }
}
