import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'models/connection_profile.dart';
import 'models/server_urls.dart';
import 'network/api_client.dart';
import 'network/connection_candidate.dart';
import 'network/connection_notice.dart';
import 'network/endpoint_utils.dart';
import 'network/device_identity.dart';
import 'network/notification_contact_cache.dart';
import 'network/push_logic.dart';
import 'network/refresh_coordinator.dart';
import 'network/websocket_client.dart';
import 'storage/local_cache_store.dart';
import 'storage/media_cache.dart';
import 'storage/secure_store.dart';
import '../features/chats/message_render.dart';
import '../features/chats/models/chat_summary.dart';
import '../features/chats/models/message_model.dart';
import '../features/chats/realtime_event_helpers.dart';

/// Counts from a per-chat initial backfill (C10 Part F diagnostics).
class BackfillDiagnostics {
  int chatsFetched = 0;
  int chatsWritten = 0;
  int messagesFetched = 0;
  int messagesWritten = 0;
  int attachmentsMetadataWritten = 0;
  int hiddenDebugRowsIgnored = 0;
  int failedChats = 0;
  String? lastError;

  @override
  String toString() =>
      'chats=$chatsFetched/$chatsWritten messages=$messagesFetched/$messagesWritten '
      'attachments=$attachmentsMetadataWritten hidden=$hiddenDebugRowsIgnored '
      'failed=$failedChats error=${lastError ?? ""}';
}

class _CandidateProbeResult {
  final ConnectionCandidate candidate;
  final bool ok;
  final Duration elapsed;

  const _CandidateProbeResult({
    required this.candidate,
    required this.ok,
    required this.elapsed,
  });

  factory _CandidateProbeResult.ok(
    ConnectionCandidate candidate,
    Duration elapsed,
  ) => _CandidateProbeResult(candidate: candidate, ok: true, elapsed: elapsed);

  factory _CandidateProbeResult.failed(
    ConnectionCandidate candidate,
    Duration elapsed,
  ) => _CandidateProbeResult(candidate: candidate, ok: false, elapsed: elapsed);
}

class RealtimeRefreshDiagnostics {
  String? lastAppliedEventCursor;
  DateTime? lastEventAt;
  DateTime? lastReconnectAt;
  String? lastCatchUpCursor;
  int lastCatchUpResultCount = 0;
  int eventsPatchedDirectly = 0;
  int eventsForcedReload = 0;
  int chatListEventReloads = 0;
  int droppedMissingChatGuid = 0;
  int droppedMalformedEvents = 0;
  int localDbWrites = 0;
  int reconnectCount = 0;
  String? lastReconnectReason;
}

class _NotificationAvatarPaths {
  final String? sender;
  final String? conversation;

  const _NotificationAvatarPaths({this.sender, this.conversation});
}

class ForegroundMessageAlert {
  final String chatGuid;
  final String messageGuid;
  final String title;
  final String? body;
  final String? handle;
  final String? avatarFilePath;
  final bool isGroup;
  final int? timestampMs;

  const ForegroundMessageAlert({
    required this.chatGuid,
    required this.messageGuid,
    required this.title,
    this.body,
    this.handle,
    this.avatarFilePath,
    this.isGroup = false,
    this.timestampMs,
  });
}

/// App-wide state: the active connection profile, the REST client built from
/// it, the realtime WebSocket client, and the last-fetched server endpoints.
///
/// Exposed via `provider` and used as the router's refresh listenable so route
/// guards re-evaluate when the profile is saved or cleared.
class AppController extends ChangeNotifier {
  final SecureStore store;
  final LocalCacheStore cache = LocalCacheStore();
  static const _customAvatarPrefix = 'custom_avatar:';
  static const inAppNotificationsStorageKey =
      'micago.in_app_notifications_enabled.v1';
  static const developerModeStorageKey = 'micago.developer_mode.v1';
  final Map<String, String> _customAvatarPaths = {};

  /// The realtime client is long-lived; home screen listens to it directly.
  final WebSocketClient ws = WebSocketClient();

  /// C19: one-shot connection notices for the UI (banner/snackbar). Emits only
  /// on real transitions, de-duplicated, so there are no noisy repeated alerts.
  final ValueNotifier<ConnectionNotice?> connectionNotice =
      ValueNotifier<ConnectionNotice?>(null);

  /// C26: whether the realtime connection is currently healthy (WS connected).
  /// The notice host clears any sticky "Reconnecting…"/offline banner the moment
  /// this flips true, so a recovered connection never leaves a stale problem
  /// banner on screen — independent of whether the one-shot derivation happened
  /// to emit a transition for the connecting→connected edge.
  final ValueNotifier<bool> connectionHealthy = ValueNotifier<bool>(false);
  ConnectionSnapshot? _lastConnectionSnapshot;
  bool _serverReachable = false;
  bool _hasCompletedFirstConnectAttempt = false;
  bool _hasEverConnected = false;
  DateTime? _connectionNoticeGraceUntil;
  DateTime _startupConnectionNoticeQuietUntil = DateTime.now().add(
    const Duration(seconds: 10),
  );
  bool _hasSuppressedStartupConnectionNotice = false;

  /// C20: the server's authoritative sync settings (incl. allowSmsSend),
  /// fetched on connect. The composer reads [allowSmsSend] from here — the
  /// client never guesses SMS sendability.
  Map<String, dynamic>? _syncSettings;
  bool get allowSmsSend => _syncSettings?['allowSmsSend'] == true;
  Map<String, dynamic>? get syncSettings => _syncSettings;

  ConnectionProfile? _profile;
  ApiClient? _api;
  ServerUrls? _serverUrls;
  ConnectionCandidate? _activeCandidate;
  final List<String> _connectionLog = <String>[];
  bool _bootstrapped = false;
  DateTime? _lastCatchUpSyncAt;
  bool _catchUpInFlight = false;
  bool _realtimeCatchingUp = false;
  final RealtimeRefreshDiagnostics realtimeDiagnostics =
      RealtimeRefreshDiagnostics();

  /// C20: owns the fallback refresh tier (reconnect backoff + poll while the
  /// socket is down). Realtime + targeted refresh stay in the controllers.
  late final RefreshCoordinator _refresh = RefreshCoordinator(
    reconnect: () => selectReachableCandidate(reason: 'reconnect'),
    catchUp: (reason) => catchUp(reason: reason, minInterval: Duration.zero),
    wsStatus: () => ws.status,
  );

  AppController({required this.store}) {
    ws.addListener(_onWebSocketStatusChanged);
    // C23: when the server's connection settings change it pushes
    // connection:updated — refresh our candidates so we follow the new LAN/
    // Public URLs without the user rescanning a QR.
    _connSub = ws.events.listen((e) {
      if (e.type == 'connection:updated') {
        unawaited(refreshServerUrls());
      } else if (e.type == 'message:new') {
        // C31: keep-alive local-notification path (no Firebase required).
        unawaited(_maybeEmitForegroundAlert(e));
        unawaited(_maybeNotifyBackgroundMessage(e));
      }
    });
  }

  StreamSubscription<WsEvent>? _connSub;

  // C31: whether the app is currently foregrounded. Drives notification dedup —
  // a realtime message that arrives while foregrounded is shown by the UI, not as
  // a system notification. The app shell updates this from lifecycle events.
  bool _foreground = true;
  bool get isForeground => _foreground;
  void setForeground(bool value) => _foreground = value;

  final Set<String> _activeChatGuids = <String>{};
  bool isChatActive(String chatGuid) => _activeChatGuids.contains(chatGuid);

  void setActiveChatGuid(String? chatGuid) {
    _activeChatGuids
      ..clear()
      ..addAll([if (chatGuid != null && chatGuid.trim().isNotEmpty) chatGuid]);
  }

  void setActiveChatGuids(Iterable<String> chatGuids) {
    _activeChatGuids
      ..clear()
      ..addAll(chatGuids.where((g) => g.trim().isNotEmpty));
  }

  final Set<String> _mutedChats = <String>{};
  bool isChatMuted(String chatGuid) => _mutedChats.contains(chatGuid);
  bool areChatsMuted(Iterable<String> chatGuids) {
    final guids = chatGuids.toList(growable: false);
    return guids.isNotEmpty && guids.every(_mutedChats.contains);
  }

  Future<void> setChatMuted(String chatGuid, bool muted) async {
    if (muted) {
      _mutedChats.add(chatGuid);
    } else {
      _mutedChats.remove(chatGuid);
    }
    unawaited(_syncChatMuteRule(chatGuid, muted));
    notifyListeners();
  }

  bool _inAppNotificationsEnabled = false;
  bool get inAppNotificationsEnabled => _inAppNotificationsEnabled;

  Future<void> setInAppNotificationsEnabled(bool enabled) async {
    if (_inAppNotificationsEnabled == enabled) return;
    _inAppNotificationsEnabled = enabled;
    await store.writeValue(inAppNotificationsStorageKey, enabled ? '1' : '0');
    notifyListeners();
  }

  /// C61: the "tap the version 7 times" developer-mode unlock is persisted, so
  /// the Developer mode entry in Settings survives leaving the page / app
  /// restarts until it's explicitly disabled from the About page.
  bool _developerModeEnabled = false;
  bool get developerModeEnabled => _developerModeEnabled;

  Future<void> setDeveloperModeEnabled(bool enabled) async {
    if (_developerModeEnabled == enabled) return;
    _developerModeEnabled = enabled;
    await store.writeValue(developerModeStorageKey, enabled ? '1' : '0');
    notifyListeners();
  }

  final StreamController<ForegroundMessageAlert> _foregroundAlertController =
      StreamController<ForegroundMessageAlert>.broadcast();

  Stream<ForegroundMessageAlert> get foregroundMessageAlerts =>
      _foregroundAlertController.stream;

  final Set<String> _foregroundAlertGuids = <String>{};
  final List<String> _foregroundAlertGuidOrder = <String>[];

  Future<void> setChatsMuted(Iterable<String> chatGuids, bool muted) async {
    var changed = false;
    for (final chatGuid in chatGuids) {
      if (muted) {
        changed = _mutedChats.add(chatGuid) || changed;
      } else {
        changed = _mutedChats.remove(chatGuid) || changed;
      }
    }
    if (!changed) return;
    unawaited(_syncChatMuteRules(chatGuids, muted));
    notifyListeners();
  }

  Future<void> _syncChatMuteRules(
    Iterable<String> chatGuids,
    bool muted,
  ) async {
    for (final chatGuid in chatGuids) {
      await _syncChatMuteRule(chatGuid, muted);
    }
  }

  Future<void> _syncChatMuteRule(String chatGuid, bool muted) async {
    final guid = chatGuid.trim();
    final api = _api;
    if (guid.isEmpty || api == null) return;
    final ok = await api.putSyncRule(
      targetKind: 'chat',
      targetValue: guid,
      syncMode: 'inherit',
      pushMode: muted ? 'muted' : 'inherit',
    );
    if (!ok) {
      debugPrint('MicaGo mute sync failed for chat $guid');
    }
  }

  /// Called by the app shell on foreground resume (lightweight refresh).
  void onResume() {
    if (hasProfile && ws.status != WsStatus.connected) {
      _connectionNoticeGraceUntil = DateTime.now().add(
        const Duration(seconds: 10),
      );
      _startupConnectionNoticeQuietUntil = DateTime.now().add(
        const Duration(seconds: 10),
      );
      _hasSuppressedStartupConnectionNotice = false;
    }
    _refresh.onResume();
  }

  ConnectionProfile? get profile => _profile;
  ApiClient? get api => _api;
  ServerUrls? get serverUrls => _serverUrls;
  ConnectionCandidate? get activeCandidate => _activeCandidate;
  List<ConnectionCandidate> get connectionCandidates =>
      _profile == null ? const [] : connectionCandidatesForProfile(_profile!);
  List<String> get connectionLog => List.unmodifiable(_connectionLog);
  bool get hasProfile => _profile?.isComplete ?? false;
  bool get bootstrapped => _bootstrapped;
  DateTime? get lastCatchUpSyncAt => _lastCatchUpSyncAt;
  bool get realtimeCatchingUp => _realtimeCatchingUp;
  String? customAvatarPathFor(String key) => _customAvatarPaths[key];

  Future<String?> shareTargetAvatarPath({
    required String customizationKey,
    String? handle,
    String? title,
  }) async {
    final custom = await _existingCustomAvatarPath(customizationKey);
    if (custom != null) return custom;
    try {
      final bytes = await contactAvatarResolver?.call(handle);
      if (bytes != null && bytes.isNotEmpty) {
        return await _writeAvatarFile(
          handle ?? title ?? customizationKey,
          bytes,
        );
      }
    } catch (_) {
      // Best-effort enhancement; share targets can fall back to the app icon.
    }
    return null;
  }

  /// Loads any persisted profile at startup.
  Future<void> bootstrap() async {
    try {
      await _bootstrapStep(
        'cache.open',
        cache.open,
        timeout: const Duration(seconds: 4),
      );
      // C63: arm the persistent media disk cache (photos/videos/previews);
      // until/unless this resolves, media falls back to memory+network.
      await _bootstrapStep(
        'media cache init',
        MediaCache.instance.init,
        timeout: const Duration(seconds: 3),
      );
      await _bootstrapStep(
        'load realtime diagnostics',
        _loadRealtimeDiagnostics,
        timeout: const Duration(seconds: 2),
      );
      await _bootstrapStep(
        'load notification preferences',
        _loadNotificationPreferences,
        timeout: const Duration(seconds: 2),
      );
      await _bootstrapStep(
        'load custom avatars',
        _loadCustomAvatars,
        timeout: const Duration(seconds: 2),
      );
      await _bootstrapStep('load profile', () async {
        _profile = await store.loadProfile();
      }, timeout: const Duration(seconds: 3));
      if (_profile != null) {
        _activeCandidate = connectionCandidatesForProfile(
          _profile!,
        ).firstOrNull;
        _hasCompletedFirstConnectAttempt = false;
        _connectionNoticeGraceUntil = DateTime.now().add(
          const Duration(seconds: 10),
        );
        _startupConnectionNoticeQuietUntil = DateTime.now().add(
          const Duration(seconds: 10),
        );
        _hasSuppressedStartupConnectionNotice = false;
        _logConnectionSelection(
          'bootstrap profile mode=${_profile!.mode.name}',
        );
        _logConnectionSelection(
          'candidates: ${connectionCandidates.join(' | ')}',
        );
      }
      _rebuildApi();
      // C29: restore the keep-alive setting (and re-arm the service if it was on).
      await _bootstrapStep(
        'load keep alive',
        _loadKeepAlive,
        timeout: const Duration(seconds: 2),
      );
    } finally {
      _bootstrapped = true;
      notifyListeners();
    }
  }

  /// C54: after a settings restore, reload the storage-backed state and
  /// reconnect. The device id metadata was dropped by the restore, so the next
  /// registration mints a fresh id (a new row in the server's Paired Devices).
  Future<void> reloadAfterRestore() async {
    _mutedChats.clear();
    await _loadNotificationPreferences();
    await _loadCustomAvatars();
    await _loadKeepAlive();
    _deviceIdFuture = null;
    _profile = await store.loadProfile();
    _activeCandidate = _profile == null
        ? null
        : connectionCandidatesForProfile(_profile!).firstOrNull;
    _rebuildApi();
    notifyListeners();
    if (_profile != null) {
      unawaited(selectReachableCandidate(reason: 'restore'));
    }
  }

  Future<void> _bootstrapStep(
    String name,
    Future<void> Function() run, {
    required Duration timeout,
  }) async {
    try {
      await run().timeout(timeout);
    } on TimeoutException {
      debugPrint('[Startup] AppController $name timed out');
    } catch (error, stack) {
      debugPrint('[Startup] AppController $name failed: $error');
      debugPrintStack(stackTrace: stack);
    }
  }

  Future<void> _refreshMutedChatsFromServer() async {
    final api = _api;
    if (api == null) return;
    final muted = await api.getMutedChatGuids();
    if (muted == null) return;
    _mutedChats
      ..clear()
      ..addAll(muted);
    notifyListeners();
  }

  Future<void> _loadNotificationPreferences() async {
    _inAppNotificationsEnabled =
        await store.readValue(inAppNotificationsStorageKey) == '1';
    // Piggybacks on this small-prefs load step (bootstrap + restore-reload).
    _developerModeEnabled =
        await store.readValue(developerModeStorageKey) == '1';
  }

  /// Builds a throwaway [ApiClient] for the connection-test screen without
  /// persisting anything.
  ApiClient buildProbeClient(ConnectionProfile profile) {
    final candidate = connectionCandidatesForProfile(profile).firstOrNull;
    return ApiClient(
      baseUrl: candidate?.baseUrl ?? profile.effectiveBaseUrl,
      token: profile.token,
    );
  }

  /// Persists [profile] and activates it as the live connection.
  Future<void> saveAndActivate(ConnectionProfile profile) async {
    await store.saveProfile(profile);
    _profile = profile;
    _serverUrls = null;
    _activeCandidate = null;
    _hasCompletedFirstConnectAttempt = false;
    _connectionNoticeGraceUntil = DateTime.now().add(
      const Duration(seconds: 10),
    );
    _startupConnectionNoticeQuietUntil = DateTime.now().add(
      const Duration(seconds: 10),
    );
    _hasSuppressedStartupConnectionNotice = false;
    _logConnectionSelection('save profile mode=${profile.mode.name}');
    _logConnectionSelection(
      'candidates: ${connectionCandidatesForProfile(profile).join(' | ')}',
    );
    _rebuildApi();
    // C29b: pairing is a user-visible connect — arm the 10s cannot-connect error.
    _armInitialConnectWatchdog();
    notifyListeners();
    unawaited(selectReachableCandidate(reason: 'profile'));
  }

  /// Fetches `GET /api/server/urls` using the active client.
  Future<void> refreshServerUrls() async {
    final api = _api;
    if (api == null) return;
    _serverUrls = await api.getServerUrls();
    await _persistEndpointCandidates(_serverUrls!);
    notifyListeners();
    unawaited(_registerDeviceIfPossible());
  }

  Future<void> _persistEndpointCandidates(ServerUrls urls) async {
    final profile = _profile;
    if (profile == null) return;
    // C23: skip the rebuild churn when the server's connection config is
    // unchanged (same revision) and we already have candidates stored.
    if (urls.connectionRevision.isNotEmpty &&
        urls.connectionRevision == profile.configRevision &&
        (profile.lanRoutes.isNotEmpty || profile.publicBaseUrl != null)) {
      return;
    }
    final currentLanBases = {
      for (final r in profile.lanRoutes) normalizeBaseUrl(r.baseUrl),
    };
    final serverUsesVisibilityFlags = urls.lan.any(
      (e) => e.hidden || !e.enabled,
    );
    // C26: keep every visible LAN route. Older servers do not expose the
    // Companion's "hidden LAN" list, so once a client has a filtered LAN set
    // from pairing, do not re-add extra LAN endpoints from /api/server/urls.
    final lanRoutes = [
      for (final e in urls.lan)
        if (e.baseUrl.trim().isNotEmpty &&
            e.isVisible &&
            (serverUsesVisibilityFlags ||
                currentLanBases.isEmpty ||
                currentLanBases.contains(normalizeBaseUrl(e.baseUrl))))
          EndpointRef(baseUrl: normalizeBaseUrl(e.baseUrl), wsUrl: e.wsUrl),
    ];
    final pub = urls.public?.enabled == true ? urls.public : null;
    // C26: a manual route pin must survive refresh. Keep the selection if its
    // URL still exists in the new candidate set; otherwise drop it (auto).
    final usableUrls = {
      for (final r in lanRoutes) normalizeBaseUrl(r.baseUrl),
      if (pub != null) normalizeBaseUrl(pub.baseUrl),
    };
    final keptSelection =
        (profile.selectedBaseUrl != null &&
            usableUrls.contains(normalizeBaseUrl(profile.selectedBaseUrl!)))
        ? profile.selectedBaseUrl
        : null;
    final next = ConnectionProfile(
      baseUrl: profile.baseUrl,
      token: profile.token,
      wsUrlOverride: profile.wsUrlOverride,
      lanRoutes: lanRoutes.isNotEmpty ? lanRoutes : null,
      selectedBaseUrl: keptSelection,
      publicBaseUrl: pub?.baseUrl,
      publicWsUrl: pub?.wsUrl,
      mode: profile.mode,
      configRevision: urls.connectionRevision,
    );
    _profile = next;
    // Keep the active candidate if it still exists; only reset when it's gone so
    // the displayed/used endpoint doesn't silently jump on a routine refresh.
    final active = _activeCandidate;
    if (active != null &&
        !usableUrls.contains(normalizeBaseUrl(active.baseUrl))) {
      _activeCandidate = null;
    }
    await store.saveProfile(next);
    _rebuildApi();
  }

  /// C26: pin a specific candidate (LAN interface or Public) as the route to use,
  /// persist it, and immediately reconnect through it. Passing null clears the
  /// pin and returns to automatic LAN-first selection.
  Future<void> selectRoute(String? baseUrl) async {
    final profile = _profile;
    if (profile == null) return;
    final normalized = baseUrl == null || baseUrl.trim().isEmpty
        ? null
        : normalizeBaseUrl(baseUrl);
    final next = profile.copyWith(selectedBaseUrl: normalized);
    _profile = next;
    _activeCandidate = null;
    await store.saveProfile(next);
    _rebuildApi();
    _logConnectionSelection('manual route selected: ${normalized ?? 'auto'}');
    notifyListeners();
    await selectReachableCandidate(reason: 'manual-route');
  }

  /// Opens the realtime WebSocket using the active profile.
  void connectWebSocket() {
    final profile = _profile;
    if (profile == null) return;
    final candidate =
        _activeCandidate ?? connectionCandidatesForProfile(profile).firstOrNull;
    if (candidate == null) return;
    _activeCandidate = candidate;
    _logConnectionSelection(
      'WS connect ${candidate.label}: ${candidate.wsUrl}',
    );
    final platform = serverPlatformFor(defaultTargetPlatform, isWeb: kIsWeb);
    ws.connect(
      candidate.wsUrl,
      profile.token,
      metadata: {
        'clientType': 'flutter',
        'platform': platform,
        'appVersion': kAppVersion,
        'name': platform == 'unknown'
            ? 'micaGO Flutter'
            : 'micaGO ${platform[0].toUpperCase()}${platform.substring(1)}',
      },
    );
  }

  /// Foreground startup/resume entry point: test candidates first, then connect.
  /// During the first attempt we suppress scary offline banners unless the attempt
  /// actually fails.
  Future<bool> connectForeground({required String reason}) {
    if (hasProfile && ws.status != WsStatus.connected) {
      _connectionNoticeGraceUntil = DateTime.now().add(
        const Duration(seconds: 10),
      );
      _startupConnectionNoticeQuietUntil = DateTime.now().add(
        const Duration(seconds: 10),
      );
      _hasSuppressedStartupConnectionNotice = false;
      // C29b: this is a user-visible connect attempt — arm the 10s watchdog so
      // the user gets a clear "can't reach the server" error instead of being
      // stuck on "Reconnecting…" forever.
      _armInitialConnectWatchdog();
    }
    return selectReachableCandidate(reason: reason);
  }

  /// C29b: surfaces a clear, user-visible error when the INITIAL connection
  /// attempt (startup or just after pairing) can't reach any server candidate
  /// within 10s. Cleared the moment a connection succeeds. Background reconnects
  /// never arm this, so it can't spam.
  final ValueNotifier<bool> initialConnectFailed = ValueNotifier<bool>(false);
  Timer? _initialConnectWatchdog;

  void _armInitialConnectWatchdog() {
    _initialConnectWatchdog?.cancel();
    initialConnectFailed.value = false;
    if (ws.status == WsStatus.connected || _serverReachable) return;
    _initialConnectWatchdog = Timer(const Duration(seconds: 10), () {
      if (ws.status != WsStatus.connected && !_serverReachable) {
        _logConnectionSelection('initial connect watchdog: no server in 10s');
        initialConnectFailed.value = true;
      }
    });
  }

  void _clearInitialConnectWatchdog() {
    _initialConnectWatchdog?.cancel();
    _initialConnectWatchdog = null;
    if (initialConnectFailed.value) initialConnectFailed.value = false;
  }

  /// Manual retry from the cannot-connect dialog.
  Future<bool> retryInitialConnect() => connectForeground(reason: 'retry');

  Future<bool> selectReachableCandidate({
    required String reason,
    ConnectionCandidateKind? skipKind,
  }) async {
    final profile = _profile;
    if (profile == null) return false;
    final allCandidates = connectionCandidatesForProfile(profile);
    final filtered = allCandidates
        .where((c) => c.kind != skipKind)
        .toList(growable: false);
    final candidates = await _orderedCandidatesForCurrentNetwork(
      profile,
      filtered,
    );
    _logConnectionSelection(
      'select candidate reason=$reason mode=${profile.mode.name}',
    );
    _logConnectionSelection('all candidates: ${allCandidates.join(' | ')}');
    if (skipKind != null || !_sameCandidateOrder(filtered, candidates)) {
      _logConnectionSelection('trying candidates: ${candidates.join(' | ')}');
    }

    var i = 0;
    while (i < candidates.length) {
      final candidate = candidates[i];
      if (candidate.kind == ConnectionCandidateKind.lan) {
        final lanRun = <ConnectionCandidate>[];
        while (i < candidates.length &&
            candidates[i].kind == ConnectionCandidateKind.lan) {
          lanRun.add(candidates[i]);
          i++;
        }
        final result = lanRun.length > 1
            ? await _probeLanRun(profile, lanRun)
            : await _probeCandidate(profile, lanRun.single);
        if (result.ok) {
          _activateReachableCandidate(result.candidate, reason);
          return true;
        }
        continue;
      }

      final result = await _probeCandidate(profile, candidate);
      i++;
      if (result.ok) {
        _activateReachableCandidate(result.candidate, reason);
        return true;
      }
    }
    _logConnectionSelection('no reachable candidate');
    _serverReachable = false;
    _hasCompletedFirstConnectAttempt = true;
    _connectionNoticeGraceUntil = null;
    _emitConnectionNotice();
    notifyListeners();
    return false;
  }

  Future<List<ConnectionCandidate>> _orderedCandidatesForCurrentNetwork(
    ConnectionProfile profile,
    List<ConnectionCandidate> candidates,
  ) async {
    if (profile.selectedBaseUrl?.trim().isNotEmpty == true ||
        (profile.mode != ConnectionMode.auto &&
            profile.mode != ConnectionMode.lanFirst)) {
      return candidates;
    }
    final public = candidates
        .where((c) => c.kind == ConnectionCandidateKind.public)
        .toList(growable: false);
    if (public.isEmpty) return candidates;
    if (!await _isLikelyCellularNetwork()) return candidates;
    final lan = candidates
        .where((c) => c.kind == ConnectionCandidateKind.lan)
        .toList(growable: false);
    _logConnectionSelection('cellular network detected: preferring Public');
    return [...public, ...lan];
  }

  Future<bool> _isLikelyCellularNetwork() async {
    try {
      final results = await Connectivity().checkConnectivity();
      return results.contains(ConnectivityResult.mobile) &&
          !results.contains(ConnectivityResult.wifi) &&
          !results.contains(ConnectivityResult.ethernet);
    } catch (error) {
      _logConnectionSelection('connectivity check failed: $error');
      return false;
    }
  }

  bool _sameCandidateOrder(
    List<ConnectionCandidate> a,
    List<ConnectionCandidate> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].baseUrl != b[i].baseUrl || a[i].kind != b[i].kind) return false;
    }
    return true;
  }

  Future<_CandidateProbeResult> _probeLanRun(
    ConnectionProfile profile,
    List<ConnectionCandidate> candidates,
  ) async {
    _logConnectionSelection(
      'checking ${candidates.length} LAN candidates in parallel',
    );
    final results = await Future.wait([
      for (final candidate in candidates) _probeCandidate(profile, candidate),
    ]);
    final reachable = results.where((r) => r.ok).toList()
      ..sort((a, b) => a.elapsed.compareTo(b.elapsed));
    if (reachable.isNotEmpty) {
      final fastest = reachable.first;
      _logConnectionSelection(
        'fastest LAN ${fastest.candidate.baseUrl} '
        '${fastest.elapsed.inMilliseconds}ms',
      );
      return fastest;
    }
    return results.isEmpty
        ? _CandidateProbeResult.failed(candidates.first, Duration.zero)
        : results.first;
  }

  Future<_CandidateProbeResult> _probeCandidate(
    ConnectionProfile profile,
    ConnectionCandidate candidate,
  ) async {
    _logConnectionSelection(
      'checking ${candidate.label}: ${candidate.baseUrl}',
    );
    final elapsed = Stopwatch()..start();
    final client = ApiClient(
      baseUrl: candidate.baseUrl,
      token: profile.token,
      timeout: const Duration(seconds: 4),
    );
    try {
      final healthy = await client.health();
      if (healthy) {
        await client.authCheck();
        elapsed.stop();
        _logConnectionSelection(
          '${candidate.label} health=true auth=true '
          '${elapsed.elapsedMilliseconds}ms',
        );
        return _CandidateProbeResult.ok(candidate, elapsed.elapsed);
      }
      elapsed.stop();
      _logConnectionSelection('${candidate.label} health=false');
      return _CandidateProbeResult.failed(candidate, elapsed.elapsed);
    } catch (error) {
      elapsed.stop();
      _logConnectionSelection('${candidate.label} failed: $error');
      return _CandidateProbeResult.failed(candidate, elapsed.elapsed);
    } finally {
      client.close();
    }
  }

  void _activateReachableCandidate(
    ConnectionCandidate candidate,
    String reason,
  ) {
    _activeCandidate = candidate;
    _serverReachable = true;
    _hasCompletedFirstConnectAttempt = true;
    _connectionNoticeGraceUntil = null;
    _logConnectionSelection('selected ${candidate.label}');
    _rebuildApi();
    // C29b: reached the server → clear any pending cannot-connect error.
    _clearInitialConnectWatchdog();
    // C29: register this device as soon as the server is reachable over REST —
    // not only when the WebSocket connects.
    unawaited(_registerDeviceIfPossible());
    unawaited(_refreshMutedChatsFromServer());
    unawaited(refreshNotificationConfig());
    _emitConnectionNotice();
    notifyListeners();
    connectWebSocket();
    unawaited(catchUp(reason: reason, minInterval: Duration.zero));
  }

  Future<void> catchUp({
    required String reason,
    Duration minInterval = const Duration(seconds: 4),
  }) async {
    final api = _api;
    if (api == null || _catchUpInFlight) return;
    final last = _lastCatchUpSyncAt;
    if (last != null && DateTime.now().difference(last) < minInterval) {
      return;
    }
    _catchUpInFlight = true;
    try {
      final cursor = realtimeDiagnostics.lastAppliedEventCursor;
      realtimeDiagnostics.lastCatchUpCursor = cursor;
      await cache.writeMetadata('last_catch_up_cursor', cursor ?? '');
      final count = await api.syncNow();
      realtimeDiagnostics.lastCatchUpResultCount = count;
      _lastCatchUpSyncAt = DateTime.now();
      await cache.writeMetadata(
        'last_catch_up_time',
        _lastCatchUpSyncAt!.millisecondsSinceEpoch.toString(),
      );
      await cache.writeMetadata('last_catch_up_result_count', '$count');
      notifyListeners();
      // C21: after the server relay refresh, pull any messages we missed via the
      // delta cursor — the correctness path that guarantees nothing is lost while
      // disconnected/backgrounded, independent of WebSocket events.
      await runDeltaSync(reason: reason);
    } catch (_) {
      // Foreground catch-up is opportunistic; normal REST loads still surface
      // actionable errors in the views that requested data.
    } finally {
      _catchUpInFlight = false;
    }
  }

  // --- C21 delta cursor sync (correctness path) --------------------------------

  int? _syncCursor; // persistent; -1/null seeds to "now" on first run
  bool _deltaInFlight = false;
  final StreamController<MessageModel> _deltaController =
      StreamController<MessageModel>.broadcast();

  /// Messages applied by the delta catch-up. Thread/chat-list controllers
  /// subscribe and patch their state (GUID dedup prevents duplicate bubbles).
  Stream<MessageModel> get deltaMessages => _deltaController.stream;

  final StreamController<void> _chatReloadController =
      StreamController<void>.broadcast();

  /// Fires when something off-band changed the chat set (e.g. the test contact
  /// was toggled) and the chat-list controller should reload from the server.
  Stream<void> get chatListReloads => _chatReloadController.stream;

  final StreamController<void> _chatSeenController =
      StreamController<void>.broadcast();

  /// Fires when the open thread advances a chat's read watermark, so the chat
  /// list re-derives the unread dot from the cache immediately.
  Stream<void> get chatSeen => _chatSeenController.stream;

  /// The authoritative "the user is looking at this conversation" signal: marks
  /// every [guids] route seen in the cache (advancing the read watermark) and
  /// notifies the chat list to re-derive the dot. Only the open thread should
  /// call this — message ingestion (WS/delta) never clears another party's dot
  /// (C47), which is what made the dot flicker/disappear when a new message
  /// arrived while a stale "active chat" was still recorded.
  Future<void> markChatsViewed(Iterable<String> guids, {int? upTo}) async {
    final ids = guids.where((g) => g.trim().isNotEmpty).toList(growable: false);
    if (ids.isEmpty) return;
    await cache.markChatsSeen(ids, upTo: upTo);
    if (!_chatSeenController.isClosed) _chatSeenController.add(null);
  }

  /// Fetches everything newer than the persisted cursor and applies it to the
  /// cache + open views, paging until caught up. Idempotent and safe to call on
  /// reconnect, resume, startup, and the fallback poll.
  Future<void> runDeltaSync({required String reason}) async {
    final api = _api;
    if (api == null || _deltaInFlight) return;
    _deltaInFlight = true;
    try {
      _syncCursor ??= int.tryParse(
        await cache.readMetadata('sync_cursor') ?? '',
      );
      var guard = 0;
      while (guard++ < 20) {
        final delta = await api.fetchDelta(since: _syncCursor);
        for (final msg in delta.messages) {
          final chatGuid = msg.chatGuid;
          if (chatGuid != null && chatGuid.isNotEmpty) {
            final isNew =
                msg.guid.isEmpty || !await cache.hasMessageGuid(msg.guid);
            await cache.upsertMessage(chatGuid, msg);
            // C47: ingestion only ever lights (or leaves) the unread dot — it
            // never advances another party's read watermark. Marking a chat read
            // is owned exclusively by the open thread (markChatsViewed), so a
            // stale "active chat" or a background→resume race can no longer make
            // an arriving message wrongly clear an existing dot. My own messages
            // are inherently seen.
            final seen = msg.isFromMe;
            final knownChat = await cache.bumpChatWithMessage(
              msg,
              markUnread: isNew && !seen,
              seen: seen,
            );
            if (!knownChat && !_chatReloadController.isClosed) {
              _chatReloadController.add(null);
            }
            if (isNew) {
              unawaited(_maybeEmitForegroundMessage(msg, chatGuid));
            }
          }
          _deltaController.add(msg);
        }
        final advanced = delta.cursor != _syncCursor;
        _syncCursor = delta.cursor;
        await cache.writeMetadata('sync_cursor', '${delta.cursor}');
        if (delta.messages.isNotEmpty) notifyListeners();
        if (!delta.hasMore) break;
        if (!advanced) break; // safety: never loop on a non-advancing cursor
      }
    } catch (_) {
      // Opportunistic; the next trigger retries.
    } finally {
      _deltaInFlight = false;
    }
  }

  /// Recomputes the connection snapshot and surfaces a one-shot notice on a
  /// real transition (C19). Called whenever WS status or the active endpoint /
  /// reachability changes. De-duplicates by only emitting on a non-null
  /// transition result; the UI clears [connectionNotice] after showing it.
  void _emitConnectionNotice() {
    final current = ConnectionSnapshot(
      ws: ws.status,
      activeKind: _activeCandidate?.kind,
      serverReachable: _serverReachable || ws.status == WsStatus.connected,
    );
    final notice = connectionNoticeFor(_lastConnectionSnapshot, current);
    _lastConnectionSnapshot = current;
    // Keep the healthy flag in lock-step with the live snapshot so the notice
    // host can clear a stale "Reconnecting…" banner the instant we reconnect,
    // even on the connecting→connected edge (which the one-shot derivation
    // intentionally reports as null to stay quiet).
    connectionHealthy.value =
        current.ws == WsStatus.connected && current.serverReachable;
    if (_shouldSuppressConnectionNotice(notice)) return;
    if (notice != null) connectionNotice.value = notice;
  }

  bool _shouldSuppressConnectionNotice(ConnectionNotice? notice) {
    if (notice == null) return false;
    if (_shouldSuppressStartupConnectionNotice(notice)) return true;
    if (!notice.isProblem) return false;
    // C26: a brief reconnect after a background→resume (or a fresh activate)
    // is expected and self-heals — don't flash "Reconnecting…" during the
    // grace window even once we've connected before. Other problems (offline,
    // dropped) still surface immediately.
    final grace = _connectionNoticeGraceUntil;
    if (notice == ConnectionNotice.reconnecting &&
        grace != null &&
        DateTime.now().isBefore(grace)) {
      return true;
    }
    if (_hasEverConnected) return false;
    if (_hasCompletedFirstConnectAttempt) return false;
    if (grace == null) return false;
    return DateTime.now().isBefore(grace);
  }

  bool _shouldSuppressStartupConnectionNotice(ConnectionNotice notice) {
    if (_hasSuppressedStartupConnectionNotice) return false;
    if (DateTime.now().isAfter(_startupConnectionNoticeQuietUntil)) {
      return false;
    }
    final isStartupNoise = switch (notice) {
      ConnectionNotice.connected ||
      ConnectionNotice.webSocketRecovered ||
      ConnectionNotice.disconnected ||
      ConnectionNotice.serverUnavailable ||
      ConnectionNotice.webSocketLost ||
      ConnectionNotice.reconnecting => true,
      ConnectionNotice.switchedToLan ||
      ConnectionNotice.switchedToPublic => false,
    };
    if (!isStartupNoise) return false;
    _hasSuppressedStartupConnectionNotice = true;
    return true;
  }

  void _onWebSocketStatusChanged() {
    if (ws.status == WsStatus.connected) {
      _serverReachable = true;
      _hasEverConnected = true;
      _hasCompletedFirstConnectAttempt = true;
      _connectionNoticeGraceUntil = null;
      _clearInitialConnectWatchdog(); // C29b: connected → clear the 10s error
    }
    // Surface a user-visible notice for any status transition (connect, lost,
    // reconnecting, disconnect). De-dup is handled in the pure derivation.
    _emitConnectionNotice();

    if (ws.status == WsStatus.connected) {
      unawaited(refreshServerUrls());
      unawaited(_handleWebSocketReconnect());
    } else if (ws.status == WsStatus.failed ||
        ws.status == WsStatus.disconnected) {
      _logConnectionSelection(
        'WS ${ws.status.name}: ${ws.lastError ?? 'closed'}',
      );
    }
    // C20: the coordinator owns all reconnect scheduling + the fallback poll —
    // covering clean disconnects and single-mode profiles, which the old
    // failed-only path missed.
    _refresh.onWsStatusChanged(ws.status);
  }

  Future<void> _handleWebSocketReconnect() async {
    realtimeDiagnostics.lastReconnectAt = DateTime.now();
    realtimeDiagnostics.reconnectCount++;
    realtimeDiagnostics.lastReconnectReason = 'websocket_connected';
    _realtimeCatchingUp = true;
    await cache.writeMetadata(
      'last_reconnect_at',
      realtimeDiagnostics.lastReconnectAt!.millisecondsSinceEpoch.toString(),
    );
    await cache.writeMetadata(
      'reconnect_count',
      '${realtimeDiagnostics.reconnectCount}',
    );
    await cache.writeMetadata('last_reconnect_reason', 'websocket_connected');
    notifyListeners();
    unawaited(_registerDeviceIfPossible());
    unawaited(refreshSyncSettings());
    try {
      await catchUp(reason: 'websocket', minInterval: Duration.zero);
    } finally {
      _realtimeCatchingUp = false;
      notifyListeners();
    }
  }

  /// Fetches the server's sync settings (server-authoritative SMS sendability).
  Future<void> refreshSyncSettings() async {
    final settings = await _api?.getSyncSettings();
    if (settings != null) {
      _syncSettings = settings;
      notifyListeners();
    }
  }

  /// Updates "Allow SMS sending through Mac" on the server, then refreshes the
  /// local copy. Returns true on success.
  Future<bool> setAllowSmsSend(bool value) async {
    final api = _api;
    if (api == null) return false;
    final current = _syncSettings ?? await api.getSyncSettings();
    if (current == null) return false;
    final updated = await api.putSyncSettings({
      ...current,
      'allowSmsSend': value,
    });
    if (updated == null) return false;
    _syncSettings = updated;
    notifyListeners();
    return true;
  }

  /// Whether the offline loopback test contact is on. null = unknown/unavailable
  /// (not yet fetched, or the server doesn't support it).
  bool? _testContactEnabled;
  bool? get testContactEnabled => _testContactEnabled;
  static const _testChatGuids = [
    'iMessage;-;test@micago.cinmou',
    'iMessage;-;micago-test-group@micago.cinmou',
  ];
  static const testContactAvatarAsset = 'lib/Assets/Server.png';

  bool isTestContactChat(String guid) => _testChatGuids.contains(guid);

  /// Fetches the current test-contact state from the server. Best-effort.
  Future<void> refreshTestContact() async {
    final config = await _api?.getTestContactConfig();
    if (config != null && config.enabled != _testContactEnabled) {
      _testContactEnabled = config.enabled;
      notifyListeners();
    }
  }

  /// Turns the offline test contact on or off on the server, then nudges the
  /// chat list to reload so the synthetic chat appears/disappears. Returns true
  /// on success.
  Future<bool> setTestContactEnabled(bool value) async {
    final api = _api;
    if (api == null) return false;
    final result = await api.setTestContact(enabled: value);
    if (result == null) return false;
    if (!result.enabled) {
      await cache.removeChats(_testChatGuids);
    }
    _testContactEnabled = result.enabled;
    notifyListeners();
    if (!_chatReloadController.isClosed) _chatReloadController.add(null);
    return true;
  }

  // C42: hidden-state management for the Settings "release" buttons.

  Future<int> hiddenChatCount() => cache.hiddenChatCount();
  Future<int> hiddenMessageCount() => cache.hiddenMessageCount();
  Future<List<ChatSummary>> hiddenChats() => cache.hiddenChats();
  Future<List<HiddenMessageRecord>> hiddenMessages() => cache.hiddenMessages();

  Future<int> releaseHiddenChats(Iterable<String> guids) async {
    final n = await cache.releaseHiddenChats(guids);
    if (!_chatReloadController.isClosed) _chatReloadController.add(null);
    return n;
  }

  Future<int> releaseHiddenMessages(Iterable<String> guids) =>
      cache.releaseHiddenMessages(guids);

  /// C19/C21u: register this client so the Companion shows a connected device.
  /// Best-effort and idempotent — sends a **stable, client-generated** device id
  /// (memoized below) on every reconnect so the server upserts the same row
  /// rather than creating duplicates. Also reports the app version, the active
  /// connection mode (LAN vs LAN+Public), and the push capability.
  bool _registerInFlight = false;
  bool _registerRerunQueued = false;
  String? _lastRegisterResult;

  /// Human-readable summary of the last device-registration attempt (for the
  /// debug diagnostics panel). Never contains the token.
  String? get lastRegisterResult => _lastRegisterResult;

  String _recordRegister(String summary) {
    _lastRegisterResult = '${DateTime.now().toIso8601String()} $summary';
    _logConnectionSelection('device register: $summary');
    notifyListeners();
    return _lastRegisterResult!;
  }

  /// Registers this device (C29c: fully instrumented + hardened). Returns a
  /// result summary; never throws and never swallows a failure silently.
  /// [force] is kept for call-site intent; an in-flight attempt is still
  /// serialized and followed by exactly one fresh registration pass.
  // The real device name, resolved once (C53) and reused for every register.
  String? _deviceName;
  Future<String> _resolveDeviceName() async =>
      _deviceName ??= await resolveDeviceName();

  Future<String> _registerDeviceIfPossible({bool force = false}) async {
    if (_registerInFlight) {
      // C57-fix: never DROP a registration request. The startup race was:
      // connect kicks off a register with pushProvider='none'; while it is in
      // flight PushService obtains the FCM token and asks to re-register as
      // pushProvider='fcm' — which used to bail out here, leaving the server
      // with provider=none and no token, so FCM pushes silently never fired
      // (UI still said "registered"). Queue exactly one re-run; it executes
      // after the in-flight attempt and reads the then-current push state.
      _registerRerunQueued = true;
      final queued = force ? 'force-queued' : 'queued';
      return _lastRegisterResult ?? '$queued behind in-flight registration';
    }
    final profile = _profile;
    if (profile == null || profile.token.trim().isEmpty) {
      return _recordRegister('skipped: no profile or empty token');
    }
    final candidates = _registrationCandidates(profile);
    if (candidates.isEmpty) {
      return _recordRegister('skipped: no candidate base URL');
    }

    _registerInFlight = true;
    try {
      final String id;
      try {
        id = await _ensureDeviceId();
      } catch (e) {
        return _recordRegister('FAILED: could not load device id: $e');
      }
      if (id.isEmpty) {
        return _recordRegister('FAILED: empty device id');
      }
      final hasPublic = candidates.any(
        (c) => c.kind == ConnectionCandidateKind.public,
      );
      final mode = hasPublic ? 'lan_public' : 'lan';
      final background = _pushEnabled || _keepAliveEnabled;
      final body = buildDeviceRegistration(
        name: await _resolveDeviceName(),
        platform: serverPlatformFor(defaultTargetPlatform, isWeb: kIsWeb),
        id: id,
        mode: mode,
        pushProvider: _pushProvider,
        pushToken: _pushToken,
        pushEnabled: _pushEnabled,
        background: background,
      );
      _logConnectionSelection(
        'device register → ${candidates.length} candidate(s) '
        'id=$id mode=$mode tokenLen=${profile.token.trim().length} '
        'provider=$_pushProvider bg=$background',
      );
      final failures = <String>[];
      final successes = <String>[];
      for (final candidate in candidates) {
        // DEDICATED short-lived client: the shared _api can be closed by a
        // concurrent _rebuildApi() (endpoint refresh), aborting the POST. Try
        // every advertised endpoint instead of stopping on the first OK: with
        // multiple LAN/Public routes the first reachable server can be stale,
        // while the Companion UI is reading the current backend's device table.
        final client = ApiClient(
          baseUrl: candidate.baseUrl,
          token: profile.token,
          timeout: const Duration(seconds: 5),
        );
        try {
          ({String? id, int status, String? error}) result = (
            id: null,
            status: 0,
            error: 'not attempted',
          );
          for (var attempt = 1; attempt <= 2; attempt++) {
            _recordRegister(
              'attempt $attempt/2 ${candidate.label} '
              '${candidate.baseUrl}',
            );
            result = await client.registerDevice(body);
            if (result.status == 200) {
              successes.add('${candidate.label} ${candidate.baseUrl}');
              break;
            }
            final failure =
                '${candidate.label} ${candidate.baseUrl} '
                        'status=${result.status} ${result.error ?? ''}'
                    .trim();
            failures.add(failure);
            _recordRegister('FAILED $failure');
            if (attempt < 2 && result.status == 0) {
              await Future<void>.delayed(const Duration(seconds: 1));
            } else {
              break;
            }
          }
        } finally {
          client.close();
        }
      }
      if (successes.isNotEmpty) {
        _startDeviceHeartbeat(id);
        final failed = failures.isEmpty
            ? ''
            : ' ; failed: ${failures.join(' | ')}';
        return _recordRegister(
          'OK id=$id on ${successes.length}/${candidates.length} endpoint(s): '
          '${successes.join(' | ')}$failed',
        );
      }
      return _recordRegister('FAILED all endpoints: ${failures.join(' | ')}');
    } finally {
      _registerInFlight = false;
      if (_registerRerunQueued) {
        _registerRerunQueued = false;
        // Re-register with the latest state (e.g. the FCM token that arrived
        // while the previous attempt was still in flight).
        unawaited(_registerDeviceIfPossible());
      }
    }
  }

  List<ConnectionCandidate> _registrationCandidates(ConnectionProfile profile) {
    final out = <ConnectionCandidate>[];
    final active = _activeCandidate;
    if (active != null && active.baseUrl.trim().isNotEmpty) out.add(active);
    out.addAll(connectionCandidates);
    out.addAll(connectionCandidatesForProfile(profile));
    final seen = <String>{};
    return [
      for (final c in out)
        if (c.baseUrl.trim().isNotEmpty && seen.add(c.baseUrl)) c,
    ];
  }

  /// Debug: force a registration attempt now and return its result summary.
  Future<String> registerDeviceNow() => _registerDeviceIfPossible(force: true);

  /// Debug: a redacted connection/registration diagnostics snapshot.
  Future<String> connectionDiagnostics() async {
    final profile = _profile;
    String deviceId = '(unavailable)';
    try {
      deviceId = await _ensureDeviceId();
    } catch (_) {}
    return [
      'profile: ${profile == null ? "none" : "set"}',
      'token: ${(profile?.token.trim().isNotEmpty ?? false) ? "present (${profile!.token.trim().length} chars)" : "MISSING"}',
      'deviceId: $deviceId',
      'activeBaseUrl: ${_activeCandidate?.baseUrl ?? "(none)"}',
      'apiBaseUrl: ${_api?.baseUrl ?? "(none)"}',
      'ws: ${ws.status.name}',
      'serverReachable: $_serverReachable',
      'candidates: ${connectionCandidates.map((c) => c.baseUrl).join(", ")}',
      'pushProvider: $_pushProvider  pushEnabled: $_pushEnabled  keepAlive: $_keepAliveEnabled',
      'lastRegister: ${_lastRegisterResult ?? "(never attempted)"}',
    ].join('\n');
  }

  // C22: push capability reported on registration, set by PushService once it
  // has (or loses) an FCM token. Defaults to "no push" so a missing/optional
  // Firebase config simply keeps WebSocket + delta sync as the only paths.
  String _pushProvider = 'none';
  String? _pushToken;
  bool _pushEnabled = false;

  // C31 notification wiring (set during app composition / by PushService).
  // Both are optional: when unset the corresponding behavior simply no-ops.

  /// Resolves a raw handle to an on-device contact name (set from ContactsService
  /// in the app composition root). Used to title local notifications with a real
  /// name rather than a bare phone/email handle.
  String? Function(String? handle)? contactNameResolver;

  /// Resolves a raw handle to the contact's avatar bytes (set from
  /// ContactsService). Used to show the sender's photo in the notification (C32).
  Future<Uint8List?> Function(String? handle)? contactAvatarResolver;
  String? Function(String? handle)? contactIdResolver;

  /// Shows a native MessagingStyle local notification through the shared,
  /// already-initialized plugin (set by [PushService] once local notifications
  /// are up, independent of Firebase). The keep-alive path calls this.
  Future<void> Function({
    required String? chatGuid,
    required String messageGuid,
    required String senderName,
    required String conversationTitle,
    String? senderKey,
    String? body,
    String? avatarFilePath,
    String? conversationAvatarFilePath,
    bool isGroup,
    int? timestampMs,
  })?
  showLocalNotification;

  /// Clears a chat's stacked conversation notification + buffer (set by
  /// [PushService]); called when the user opens that chat.
  Future<void> Function(String chatGuid)? clearChatNotification;

  // The server's notification preview mode governs how much a local notification
  // shows. We default to the common "sender + text" layout; `none`/`sender` hide
  // the text. (The FCM path is gated server-side; this keeps the local path in
  // step for the default.)
  String _notificationPreview = 'sender_and_text';
  String get notificationPreview => _notificationPreview;
  bool get notificationShowsMessageText =>
      _notificationPreview == 'sender_and_text';

  Future<void> refreshNotificationConfig() async {
    final api = _api;
    if (api == null) return;
    try {
      final config = await api.getNotificationConfig();
      final preview = config?.preview.trim();
      if (preview == null || preview.isEmpty) return;
      if (_notificationPreview == preview) return;
      _notificationPreview = preview;
      notifyListeners();
    } catch (error) {
      debugPrint('MicaGo notification config refresh failed: $error');
    }
  }

  Future<void> setNotificationShowsMessageText(bool enabled) async {
    final api = _api;
    if (api == null) return;
    final next = enabled ? 'sender_and_text' : 'sender';
    if (_notificationPreview == next) return;
    final previous = _notificationPreview;
    _notificationPreview = next;
    notifyListeners();
    try {
      final updated = await api.setNotificationPreview(next);
      final preview = updated?.preview.trim();
      if (preview != null &&
          preview.isNotEmpty &&
          preview != _notificationPreview) {
        _notificationPreview = preview;
        notifyListeners();
      }
    } catch (error) {
      _notificationPreview = previous;
      notifyListeners();
      debugPrint('MicaGo notification preview update failed: $error');
    }
  }

  // C31 diagnostics -----------------------------------------------------------
  String? _notificationPermission; // 'granted' | 'denied' | null = unknown
  String? get notificationPermission => _notificationPermission;
  void noteNotificationPermission(bool? granted) {
    final v = granted == null ? null : (granted ? 'granted' : 'denied');
    if (_notificationPermission == v) return;
    _notificationPermission = v;
    notifyListeners();
  }

  String? _lastNotificationSource; // timestamped 'FCM' | 'keep-alive'
  String? get lastNotificationSource => _lastNotificationSource;
  void noteNotificationSource(String source) {
    _lastNotificationSource = '${DateTime.now().toIso8601String()} $source';
    notifyListeners();
  }

  String? _lastReplyResult; // timestamped direct-reply outcome
  String? get lastReplyResult => _lastReplyResult;
  void noteReplyResult(String result) {
    _lastReplyResult = '${DateTime.now().toIso8601String()} $result';
    notifyListeners();
  }

  Future<void> _maybeEmitForegroundAlert(WsEvent e) async {
    final msg = messageFromWsEvent(e);
    if (msg == null) return;
    await _maybeEmitForegroundMessage(msg, chatGuidFromWsEvent(e));
  }

  Future<void> _maybeEmitForegroundMessage(
    MessageModel msg,
    String? chatGuid,
  ) async {
    final guid = (chatGuid ?? msg.chatGuid ?? '').trim();
    if (!_foreground || guid.isEmpty || msg.isFromMe) return;
    if (isChatActive(guid) || isChatMuted(guid)) return;
    if (isReactionMessage(msg)) return;
    final messageGuid = msg.guid.trim();
    if (messageGuid.isNotEmpty && !_rememberForegroundAlertGuid(messageGuid)) {
      return;
    }
    if (_foregroundAlertController.isClosed) return;
    final isGroup = _isGroupChatGuid(guid);
    final contactName = contactNameResolver?.call(msg.handleId);
    final senderName = messageNotificationTitle(
      contactName: contactName,
      handle: msg.handleId,
    );
    final conversationTitle = isGroup
        ? await _groupConversationTitle(msg, guid)
        : senderName;
    final avatars = await _notificationAvatarPaths(
      chatGuid: guid,
      handle: msg.handleId,
      senderName: senderName,
      isGroup: isGroup,
    );
    _foregroundAlertController.add(
      ForegroundMessageAlert(
        chatGuid: guid,
        messageGuid: messageGuid,
        title: conversationTitle,
        body: messagePreviewText(msg),
        handle: msg.handleId,
        avatarFilePath: avatars.conversation ?? avatars.sender,
        isGroup: isGroup,
        timestampMs: msg.dateCreated,
      ),
    );
  }

  bool _rememberForegroundAlertGuid(String guid) {
    if (!_foregroundAlertGuids.add(guid)) return false;
    _foregroundAlertGuidOrder.add(guid);
    while (_foregroundAlertGuidOrder.length > 96) {
      _foregroundAlertGuids.remove(_foregroundAlertGuidOrder.removeAt(0));
    }
    return true;
  }

  /// C31/C32: when the app is backgrounded and the keep-alive service is holding
  /// the socket open (no Firebase needed), turn an incoming realtime message into
  /// a native MessagingStyle notification — contact name + avatar, stacked per
  /// chat, same formatting as the FCM path. Foreground messages are shown by the
  /// UI, so this no-ops; the shared per-chat id + message-guid dedup means any
  /// FCM notification for the same message collapses into one.
  Future<void> _maybeNotifyBackgroundMessage(WsEvent e) async {
    if (_foreground || !_keepAliveEnabled) return;
    final show = showLocalNotification;
    if (show == null) return; // local notifications not initialized yet
    final msg = messageFromWsEvent(e);
    if (msg == null || msg.isFromMe) return;
    if (isReactionMessage(msg)) {
      return; // tapbacks shouldn't raise a notification
    }
    final chatGuid = chatGuidFromWsEvent(e);
    if (chatGuid != null && isChatMuted(chatGuid)) return;
    final isGroup = _isGroupChatGuid(chatGuid);
    final contactName = contactNameResolver?.call(msg.handleId);
    final senderName = messageNotificationTitle(
      contactName: contactName,
      handle: msg.handleId,
    );
    final conversationTitle = isGroup
        ? await _groupConversationTitle(msg, chatGuid)
        : senderName;
    final body = localNotificationBody(
      messagePreviewText(msg),
      _notificationPreview,
    );
    final avatars = await _notificationAvatarPaths(
      chatGuid: chatGuid,
      handle: msg.handleId,
      senderName: senderName,
      isGroup: isGroup,
    );
    await show(
      chatGuid: chatGuid,
      messageGuid: msg.guid,
      senderName: senderName,
      senderKey: msg.handleId ?? senderName,
      conversationTitle: conversationTitle,
      body: body,
      avatarFilePath: avatars.sender,
      conversationAvatarFilePath: avatars.conversation,
      isGroup: isGroup,
      timestampMs: msg.dateCreated,
    );
    noteNotificationSource('keep-alive');
  }

  bool _isGroupChatGuid(String? chatGuid) => (chatGuid ?? '').contains(';+;');

  Future<String> _groupConversationTitle(
    MessageModel msg,
    String? chatGuid,
  ) async {
    final rawTitle = msg.raw?['chatDisplayName'];
    final title = rawTitle is String ? rawTitle.trim() : '';
    if (title.isNotEmpty) return title;
    final groupTitle = msg.groupTitle?.trim() ?? '';
    if (groupTitle.isNotEmpty) return groupTitle;
    final cached = await _cachedChatTitle(chatGuid);
    if (cached != null) return cached;
    final guid = chatGuid?.trim() ?? '';
    if (guid.isNotEmpty && !guid.contains(';+;')) return guid;
    return 'Group chat';
  }

  Future<String?> _cachedChatTitle(String? chatGuid) async {
    final guid = chatGuid?.trim() ?? '';
    if (guid.isEmpty) return null;
    try {
      final chats = await cache.listChats(
        includeDebug: true,
        includeHidden: true,
      );
      for (final chat in chats) {
        if (chat.guid == guid) {
          final title = chat
              .displayTitle(resolveName: contactNameResolver)
              .trim();
          return title.isNotEmpty ? title : null;
        }
      }
    } catch (_) {
      // Cache lookup is best-effort; notification should still be shown.
    }
    return null;
  }

  Future<_NotificationAvatarPaths> _notificationAvatarPaths({
    required String? chatGuid,
    required String? handle,
    required String senderName,
    required bool isGroup,
  }) async {
    final senderCustom = await _customSenderAvatarPath(
      chatGuid: chatGuid,
      handle: handle,
      isGroup: isGroup,
    );
    var sender = senderCustom;
    if (sender == null) {
      try {
        final bytes = await contactAvatarResolver?.call(handle);
        if (bytes != null && bytes.isNotEmpty) {
          sender = await _writeAvatarFile(handle ?? senderName, bytes);
        }
      } catch (_) {
        sender = null;
      }
    }

    final groupAvatar = isGroup
        ? await _existingCustomAvatarPath(_groupAvatarKey(chatGuid))
        : null;
    return _NotificationAvatarPaths(
      sender: sender,
      conversation: groupAvatar ?? (isGroup ? null : sender),
    );
  }

  Future<String?> _customSenderAvatarPath({
    required String? chatGuid,
    required String? handle,
    required bool isGroup,
  }) async {
    final contactId = contactIdResolver?.call(handle)?.trim() ?? '';
    if (contactId.isNotEmpty) {
      final path = await _existingCustomAvatarPath('contact:$contactId');
      if (path != null) return path;
    }
    if (!isGroup) {
      final path = await _existingCustomAvatarPath(_chatAvatarKey(chatGuid));
      if (path != null) return path;
    }
    return null;
  }

  String? _groupAvatarKey(String? chatGuid) {
    final guid = chatGuid?.trim() ?? '';
    return guid.isEmpty ? null : 'group:$guid';
  }

  String? _chatAvatarKey(String? chatGuid) {
    final guid = chatGuid?.trim() ?? '';
    return guid.isEmpty ? null : 'chat:$guid';
  }

  Future<String?> _existingCustomAvatarPath(String? key) async {
    if (key == null || key.isEmpty) return null;
    final path = _customAvatarPaths[key]?.trim() ?? '';
    if (path.isEmpty) return null;
    try {
      return await File(path).exists() ? path : null;
    } catch (_) {
      return null;
    }
  }

  /// Writes contact-avatar bytes to a stable temp file (one per contact key) so
  /// the notification plugin can reference it as a bitmap. Best-effort.
  // C60: keep the FCM background isolate's contact cache fresh. The isolate
  // can't reach ContactsService, so the main isolate persists handle →
  // {contact name, avatar file} whenever the chat list is loaded; pushes then
  // show the real name + photo instead of the raw handle. Throttled — the
  // resolution walk + file writes shouldn't run on every silent reload.
  DateTime? _notifContactCacheSyncedAt;

  Future<void> syncNotificationContactCache(
    List<ChatSummary> chats, {
    bool force = false,
  }) async {
    final last = _notifContactCacheSyncedAt;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 10)) {
      return;
    }
    _notifContactCacheSyncedAt = DateTime.now();
    try {
      final entries = <String, NotificationContact>{};
      Directory? avatarDir;
      for (final chat in chats) {
        if (chat.isGroup) continue;
        if (entries.length >= notificationContactCacheMax) break;
        final handle = chat.chatIdentifier?.trim() ?? '';
        if (handle.isEmpty) continue;
        final name = contactNameResolver?.call(handle)?.trim();
        // Custom avatar (user-set) wins; else the contact photo, written to a
        // stable file under app support (NOT the purgeable temp dir — the
        // background isolate may read it days later).
        var avatarPath = await _customSenderAvatarPath(
          chatGuid: chat.guid,
          handle: handle,
          isGroup: false,
        );
        if (avatarPath == null) {
          try {
            final bytes = await contactAvatarResolver?.call(handle);
            if (bytes != null && bytes.isNotEmpty) {
              if (avatarDir == null) {
                final support = await getApplicationSupportDirectory();
                avatarDir = Directory(p.join(support.path, 'notif-avatars'));
                await avatarDir.create(recursive: true);
              }
              final safe = handle.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
              final file = File(p.join(avatarDir.path, '$safe.png'));
              // Cheap change detector: rewrite only when the size differs.
              if (!await file.exists() ||
                  (await file.length()) != bytes.length) {
                await file.writeAsBytes(bytes, flush: true);
              }
              avatarPath = file.path;
            }
          } catch (_) {
            // No photo — the name alone is still worth caching.
          }
        }
        if ((name != null && name.isNotEmpty) || avatarPath != null) {
          entries[handle] = NotificationContact(
            name: name,
            avatarPath: avatarPath,
          );
        }
      }
      if (entries.isNotEmpty) {
        await writeNotificationContactCache(store, entries);
      }
    } catch (_) {
      // Best-effort; pushes fall back to the server-provided name/handle.
    }
  }

  Future<String?> _writeAvatarFile(String key, Uint8List bytes) async {
    try {
      final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
      final file = File('${Directory.systemTemp.path}/micago_avatar_$safe.png');
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  // C29: optional Android keep-alive foreground service. Persisted; default off.
  // When on, the device reports `background: true` and a foreground service keeps
  // the WebSocket alive. Firebase is NOT required for this.
  static const MethodChannel _keepAliveChannel = MethodChannel(
    'micago/keepalive',
  );
  static const String _keepAlivePrefKey = 'micago.keepalive.v1';
  bool _keepAliveEnabled = false;
  bool get keepAliveEnabled => _keepAliveEnabled;

  /// Turn the keep-alive foreground service on/off, persist the choice, and
  /// re-register so the Companion shows the updated background status.
  Future<void> setKeepAliveEnabled(bool enabled) async {
    _keepAliveEnabled = enabled;
    await store.writeValue(_keepAlivePrefKey, enabled ? '1' : '0');
    await _applyKeepAlive(enabled);
    notifyListeners();
    unawaited(_registerDeviceIfPossible());
  }

  Future<void> _loadKeepAlive() async {
    _keepAliveEnabled = (await store.readValue(_keepAlivePrefKey)) == '1';
    if (_keepAliveEnabled) await _applyKeepAlive(true);
  }

  Future<void> _applyKeepAlive(bool enabled) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _keepAliveChannel.invokeMethod(enabled ? 'start' : 'stop');
    } catch (_) {
      // Platform channel unavailable (non-Android / older build) → no-op.
    }
  }

  /// Called by [PushService] when the FCM token is obtained, refreshed, or
  /// cleared. Re-registers this device so the server can wake it (C22).
  Future<void> updatePushRegistration({
    required String provider,
    required String? token,
    required bool enabled,
  }) async {
    _pushProvider = provider;
    _pushToken = token;
    _pushEnabled = enabled;
    await _registerDeviceIfPossible();
    notifyListeners();
  }

  // C27: push status surfaced to the Settings → Notifications card.
  String get pushProvider => _pushProvider;
  bool get pushEnabled => _pushEnabled;
  bool get pushConfigured => _pushEnabled && (_pushToken?.isNotEmpty ?? false);

  /// C22: a chat GUID requested via a notification tap. The shell listens and
  /// opens the conversation (after a delta sync) when possible.
  final ValueNotifier<String?> pendingOpenChat = ValueNotifier<String?>(null);
  void requestOpenChat(String chatGuid) {
    if (chatGuid.isEmpty) return;
    pendingOpenChat.value = chatGuid;
    // C32: opening a chat dismisses its stacked conversation notification.
    clearChatNotification?.call(chatGuid);
  }

  void clearPendingOpenChat() => pendingOpenChat.value = null;

  /// Whether the realtime WebSocket is currently connected. Used by the push
  /// path to apply BlueBubbles' dedup rule: if the socket is live it already
  /// delivered the event, so the FCM wake is ignored (C22).
  bool get isRealtimeConnected => ws.status == WsStatus.connected;

  // C21u: keep this device "connected" on the server by refreshing its
  // last-seen time every 30s. When the app/network goes away the ticks stop and
  // the device naturally falls out of the server's connected window.
  Timer? _heartbeatTimer;
  void _startDeviceHeartbeat(String id) {
    _heartbeatTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_api?.deviceHeartbeat(id) ?? Future<void>.value());
    });
  }

  // The stable device id is loaded/created exactly once; the memoized Future
  // makes concurrent registrations (reconnect + resume + startup) converge on
  // the same id, so they can never race into two server rows.
  Future<String>? _deviceIdFuture;
  Future<String> _ensureDeviceId() =>
      _deviceIdFuture ??= _loadOrCreateDeviceId();

  Future<String> _loadOrCreateDeviceId() async {
    final existing = await cache.readMetadata('device_id');
    if (existing != null && existing.isNotEmpty) return existing;
    final id = generateStableDeviceId();
    await cache.writeMetadata('device_id', id);
    return id;
  }

  Future<bool> markRealtimeEventApplied(
    WsEvent event, {
    int localDbWrites = 1,
  }) async {
    final cursor = realtimeCursorForEvent(event);
    final previous = realtimeDiagnostics.lastAppliedEventCursor;
    if (cursor != null && _shouldAdvanceCursor(previous, cursor)) {
      realtimeDiagnostics.lastAppliedEventCursor = cursor;
      await cache.writeMetadata('last_applied_event_cursor', cursor);
    }
    realtimeDiagnostics.lastEventAt = DateTime.now();
    realtimeDiagnostics.eventsPatchedDirectly++;
    realtimeDiagnostics.localDbWrites += localDbWrites;
    await cache.writeMetadata(
      'last_event_at',
      realtimeDiagnostics.lastEventAt!.millisecondsSinceEpoch.toString(),
    );
    await _writeCounter(
      'events_patched_directly',
      realtimeDiagnostics.eventsPatchedDirectly,
    );
    await _writeCounter(
      'realtime_local_db_writes',
      realtimeDiagnostics.localDbWrites,
    );
    notifyListeners();
    return cursor != null;
  }

  Future<void> recordRealtimeFallback({
    bool missingChatGuid = false,
    bool malformed = false,
    bool chatListReload = false,
  }) async {
    realtimeDiagnostics.eventsForcedReload++;
    if (missingChatGuid) realtimeDiagnostics.droppedMissingChatGuid++;
    if (malformed) realtimeDiagnostics.droppedMalformedEvents++;
    if (chatListReload) realtimeDiagnostics.chatListEventReloads++;
    await _writeCounter(
      'events_forced_reload',
      realtimeDiagnostics.eventsForcedReload,
    );
    await _writeCounter(
      'dropped_missing_chat_guid',
      realtimeDiagnostics.droppedMissingChatGuid,
    );
    await _writeCounter(
      'dropped_malformed_events',
      realtimeDiagnostics.droppedMalformedEvents,
    );
    await _writeCounter(
      'chat_list_event_reloads',
      realtimeDiagnostics.chatListEventReloads,
    );
    notifyListeners();
  }

  Future<void> _writeCounter(String key, int value) =>
      cache.writeMetadata(key, '$value');

  Future<void> _loadRealtimeDiagnostics() async {
    realtimeDiagnostics.lastAppliedEventCursor = await cache.readMetadata(
      'last_applied_event_cursor',
    );
    realtimeDiagnostics.lastCatchUpCursor = await cache.readMetadata(
      'last_catch_up_cursor',
    );
    realtimeDiagnostics.lastReconnectReason = await cache.readMetadata(
      'last_reconnect_reason',
    );
    realtimeDiagnostics.lastEventAt = _dateFromMetadata(
      await cache.readMetadata('last_event_at'),
    );
    realtimeDiagnostics.lastReconnectAt = _dateFromMetadata(
      await cache.readMetadata('last_reconnect_at'),
    );
    realtimeDiagnostics.lastCatchUpResultCount =
        int.tryParse(
          await cache.readMetadata('last_catch_up_result_count') ?? '',
        ) ??
        0;
    realtimeDiagnostics.eventsPatchedDirectly =
        int.tryParse(
          await cache.readMetadata('events_patched_directly') ?? '',
        ) ??
        0;
    realtimeDiagnostics.eventsForcedReload =
        int.tryParse(await cache.readMetadata('events_forced_reload') ?? '') ??
        0;
    realtimeDiagnostics.chatListEventReloads =
        int.tryParse(
          await cache.readMetadata('chat_list_event_reloads') ?? '',
        ) ??
        0;
    realtimeDiagnostics.droppedMissingChatGuid =
        int.tryParse(
          await cache.readMetadata('dropped_missing_chat_guid') ?? '',
        ) ??
        0;
    realtimeDiagnostics.droppedMalformedEvents =
        int.tryParse(
          await cache.readMetadata('dropped_malformed_events') ?? '',
        ) ??
        0;
    realtimeDiagnostics.localDbWrites =
        int.tryParse(
          await cache.readMetadata('realtime_local_db_writes') ?? '',
        ) ??
        0;
    realtimeDiagnostics.reconnectCount =
        int.tryParse(await cache.readMetadata('reconnect_count') ?? '') ?? 0;
  }

  DateTime? _dateFromMetadata(String? raw) {
    final millis = int.tryParse(raw ?? '');
    if (millis == null || millis <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  bool _shouldAdvanceCursor(String? previous, String next) {
    if (previous == null || previous.isEmpty) return true;
    final prevNum = _numericCursor(previous);
    final nextNum = _numericCursor(next);
    if (prevNum != null && nextNum != null) return nextNum > prevNum;
    if (prevNum != null && nextNum == null) return false;
    return previous != next;
  }

  int? _numericCursor(String cursor) {
    if (!cursor.startsWith('n:')) return null;
    return int.tryParse(cursor.substring(2));
  }

  /// Local cache warm-up after pairing. Fetches the visible chat list, then the
  /// latest renderable messages for each chat, using the server's authoritative
  /// `recentMessagesPerChat` setting when available. This does not control the
  /// server backfill strategy; Sync Control is the source of truth for that.
  Future<BackfillDiagnostics> backfill(
    ConnectionProfile profile, {
    void Function(String message)? onProgress,
  }) async {
    final client = buildProbeClient(profile);
    final diag = BackfillDiagnostics();
    try {
      await cache.open();
      // Ensure realtime catch-up first so the relay has fresh rows to serve.
      try {
        await client.syncNow();
      } catch (_) {
        /* opportunistic */
      }

      var perChat = 100;
      final settings = await client.getSyncSettings();
      final configuredDepth = settings?['recentMessagesPerChat'];
      if (configuredDepth is int && configuredDepth > 0) {
        perChat = configuredDepth;
      }

      onProgress?.call('Fetching chats…');
      final chats = await client.getChats();
      await cache.upsertChats(chats);
      diag.chatsFetched = chats.length;
      diag.chatsWritten = chats.length;

      var i = 0;
      for (final chat in chats) {
        i++;
        onProgress?.call('Syncing chat $i of ${chats.length}…');
        try {
          final msgs = await client.getMessages(chat.guid, limit: perChat);
          await cache.replaceServerPage(chat.guid, msgs);
          diag.messagesFetched += msgs.length;
          diag.messagesWritten += msgs.where((m) => !m.isDebugOnly).length;
          diag.hiddenDebugRowsIgnored += msgs
              .where((m) => m.isDebugOnly)
              .length;
          diag.attachmentsMetadataWritten += msgs.fold<int>(
            0,
            (sum, m) => sum + m.attachments.length,
          );
        } catch (error) {
          diag.failedChats++;
          diag.lastError = error.toString();
        }
      }
      await cache.writeMetadata(
        'last_bootstrap_time',
        DateTime.now().millisecondsSinceEpoch.toString(),
      );
      await cache.writeMetadata(
        'last_write_count',
        (diag.chatsWritten + diag.messagesWritten).toString(),
      );
      await cache.writeMetadata(
        'last_attachment_metadata_count',
        diag.attachmentsMetadataWritten.toString(),
      );
      await cache.writeMetadata('last_error', diag.lastError ?? '');
      onProgress?.call('Sync complete (${diag.messagesFetched} messages).');
    } catch (error) {
      diag.lastError = error.toString();
      await cache.writeMetadata('last_error', diag.lastError!);
      rethrow;
    } finally {
      client.close();
    }
    return diag;
  }

  /// Clears the saved profile and tears down clients.
  Future<void> signOut() async {
    ws.disconnect();
    await store.clearProfile();
    await cache.clearAll();
    _api?.close();
    _api = null;
    _profile = null;
    _serverUrls = null;
    _activeCandidate = null;
    _customAvatarPaths.clear();
    notifyListeners();
  }

  Future<void> setCustomAvatarFromFile(String key, String sourcePath) async {
    final normalizedKey = key.trim();
    if (normalizedKey.isEmpty) return;
    final source = File(sourcePath);
    if (!await source.exists()) return;
    final dir = await getApplicationSupportDirectory();
    final avatarDir = Directory(p.join(dir.path, 'custom-avatars'));
    await avatarDir.create(recursive: true);
    final ext = p.extension(sourcePath).toLowerCase();
    final safeExt = ext.isEmpty ? '.jpg' : ext;
    final safeKey = normalizedKey.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final dest = File(p.join(avatarDir.path, '$safeKey$safeExt'));
    await source.copy(dest.path);
    final previous = _customAvatarPaths[normalizedKey];
    _customAvatarPaths[normalizedKey] = dest.path;
    await cache.writeMetadata('$_customAvatarPrefix$normalizedKey', dest.path);
    if (previous != null && previous != dest.path) {
      _deleteFileQuietly(previous);
    }
    notifyListeners();
  }

  Future<void> setCustomAvatarBytes(String key, Uint8List bytes) async {
    final normalizedKey = key.trim();
    if (normalizedKey.isEmpty || bytes.isEmpty) return;
    final dir = await getApplicationSupportDirectory();
    final avatarDir = Directory(p.join(dir.path, 'custom-avatars'));
    await avatarDir.create(recursive: true);
    final safeKey = normalizedKey.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final dest = File(p.join(avatarDir.path, '$safeKey.png'));
    await dest.writeAsBytes(bytes, flush: true);
    final previous = _customAvatarPaths[normalizedKey];
    _customAvatarPaths[normalizedKey] = dest.path;
    await cache.writeMetadata('$_customAvatarPrefix$normalizedKey', dest.path);
    if (previous != null && previous != dest.path) {
      _deleteFileQuietly(previous);
    }
    notifyListeners();
  }

  Future<void> clearCustomAvatar(String key) async {
    final normalizedKey = key.trim();
    if (normalizedKey.isEmpty) return;
    final previous = _customAvatarPaths.remove(normalizedKey);
    await cache.deleteMetadata('$_customAvatarPrefix$normalizedKey');
    if (previous != null) {
      _deleteFileQuietly(previous);
    }
    notifyListeners();
  }

  void _deleteFileQuietly(String path) {
    unawaited(() async {
      try {
        await File(path).delete();
      } catch (_) {
        // Best-effort cleanup; stale local avatar files should not block the UI.
      }
    }());
  }

  Future<void> _loadCustomAvatars() async {
    final rows = await cache.readMetadataWithPrefix(_customAvatarPrefix);
    _customAvatarPaths
      ..clear()
      ..addEntries(
        rows.entries.map(
          (entry) => MapEntry(
            entry.key.substring(_customAvatarPrefix.length),
            entry.value,
          ),
        ),
      );
  }

  void _rebuildApi() {
    _api?.close();
    final profile = _profile;
    final candidate = profile == null
        ? null
        : (_activeCandidate ??
              connectionCandidatesForProfile(profile).firstOrNull);
    _activeCandidate = candidate;
    _api = profile != null && candidate != null && profile.token.isNotEmpty
        ? ApiClient(baseUrl: candidate.baseUrl, token: profile.token)
        : null;
  }

  void _logConnectionSelection(String message) {
    final line = '${DateTime.now().toIso8601String()} $message';
    debugPrint('[MicaGo connection] $line');
    _connectionLog.add(line);
    if (_connectionLog.length > 80) {
      _connectionLog.removeRange(0, _connectionLog.length - 80);
    }
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    _initialConnectWatchdog?.cancel();
    unawaited(_connSub?.cancel());
    _refresh.dispose();
    unawaited(_deltaController.close());
    unawaited(_chatReloadController.close());
    unawaited(_chatSeenController.close());
    unawaited(_foregroundAlertController.close());
    ws.removeListener(_onWebSocketStatusChanged);
    ws.dispose();
    _api?.close();
    connectionNotice.dispose();
    connectionHealthy.dispose();
    initialConnectFailed.dispose();
    unawaited(cache.close());
    super.dispose();
  }
}

extension _FirstOrNull<E> on List<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
