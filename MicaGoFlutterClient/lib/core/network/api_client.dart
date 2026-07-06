import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../features/chats/models/chat_summary.dart';
import '../../features/chats/models/message_model.dart';
import '../models/server_urls.dart';
import 'endpoint_utils.dart';

/// Result of a cursor delta fetch (C21 catch-up). [cursor] is the new persistent
/// cursor to store; [messages] are oldest-first; [chatGuids] are the chats to
/// refresh in the list.
class MessageDelta {
  final List<MessageModel> messages;
  final List<String> chatGuids;
  final int cursor;
  final bool hasMore;
  const MessageDelta({
    required this.messages,
    required this.chatGuids,
    required this.cursor,
    required this.hasMore,
  });
}

class TestContactConfig {
  final bool available;
  final bool enabled;

  const TestContactConfig({required this.available, required this.enabled});

  factory TestContactConfig.fromJson(Map<String, dynamic> json) {
    return TestContactConfig(
      available: (json['available'] as bool?) ?? true,
      enabled: (json['enabled'] as bool?) ?? false,
    );
  }
}

class MessageActionCapabilities {
  final bool available;
  final bool edit;
  final bool retract;
  final bool delete;
  final String? reason;

  const MessageActionCapabilities({
    this.available = false,
    this.edit = false,
    this.retract = false,
    this.delete = false,
    this.reason,
  });

  factory MessageActionCapabilities.fromJson(Map<String, dynamic> json) =>
      MessageActionCapabilities(
        available: (json['available'] as bool?) ?? false,
        edit: (json['edit'] as bool?) ?? false,
        retract: (json['retract'] as bool?) ?? false,
        delete: (json['delete'] as bool?) ?? false,
        reason: json['reason'] as String?,
      );
}

class ServerNotificationConfig {
  final bool enabled;
  final String provider;
  final String preview;
  final bool fcmServiceAccountConfigured;
  final bool fcmClientConfigured;

  const ServerNotificationConfig({
    required this.enabled,
    required this.provider,
    required this.preview,
    required this.fcmServiceAccountConfigured,
    required this.fcmClientConfigured,
  });

  factory ServerNotificationConfig.fromJson(Map<String, dynamic> json) {
    return ServerNotificationConfig(
      enabled: (json['enabled'] as bool?) ?? false,
      provider: (json['provider'] as String?) ?? 'none',
      preview: (json['preview'] as String?) ?? 'sender_and_text',
      fcmServiceAccountConfigured:
          (json['fcmServiceAccountConfigured'] as bool?) ?? false,
      fcmClientConfigured: (json['fcmClientConfigured'] as bool?) ?? false,
    );
  }
}

/// A structured error from a MicaGo REST call. [code] is the stable
/// machine-readable string from the server error envelope (`{"error":{...}}`)
/// or a client-side code (`network_error`, `timeout`, `bad_response`).
class ApiException implements Exception {
  final String code;
  final String message;
  final int? statusCode;

  const ApiException({
    required this.code,
    required this.message,
    this.statusCode,
  });

  @override
  String toString() =>
      'ApiException($code'
      '${statusCode != null ? ' [$statusCode]' : ''}): $message';

  /// A plain-language explanation suitable for the UI. Never contains the token.
  /// Cloudflare 5xx (520–530) are mapped to tunnel/origin guidance.
  String get friendly {
    final s = statusCode;
    if (s == 530) {
      return 'Cloudflare reached the hostname but could not resolve/connect to '
          'the configured origin (530). Check the selected endpoint, tunnel '
          'route, and Public URL — the tunnel may not be running.';
    }
    if (s == 502 || s == 504) {
      return 'The remote endpoint was reached, but the server behind it did not '
          'respond ($s). Make sure MicaGo is running and the tunnel forwards to '
          'its port.';
    }
    if (s != null && s >= 520 && s <= 527) {
      return 'Cloudflare could not reach the origin server ($s). Check the '
          'tunnel and that MicaGo is running.';
    }
    switch (code) {
      case 'unauthorized':
        return 'The bearer token was rejected (401). Re-pair with the server.';
      case 'timeout':
        return 'The server did not respond in time.';
      case 'network_error':
        return 'Could not reach the server. Check the URL and your network.';
      case 'bad_response':
        return 'Unexpected response — is this a MicaGo server?';
      default:
        return s != null ? '$message ($s)' : message;
    }
  }
}

/// Minimal REST client for the MicaGo server.
///
/// Only the endpoints needed for the C0 foundation are implemented:
/// `GET /api/health`, `POST /api/auth/check`, `GET /api/server/urls`.
/// The bearer token is attached to every authenticated call; it is never
/// logged.
class ApiClient {
  final String baseUrl;
  final String token;
  final http.Client _http;
  final Duration timeout;

  ApiClient({
    required this.baseUrl,
    required this.token,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 12),
  }) : _http = httpClient ?? http.Client();

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse('${normalizeBaseUrl(baseUrl)}$path');
    if (query == null || query.isEmpty) return base;
    return base.replace(queryParameters: {...base.queryParameters, ...query});
  }

  Map<String, String> get _authHeaders => {
    'Authorization': 'Bearer $token',
    'Accept': 'application/json',
  };
  Map<String, String> get _jsonHeaders => {
    ..._authHeaders,
    'Content-Type': 'application/json',
  };

  /// The exact URLs the diagnostics view probes (no token in the URL).
  String get healthUrl => _uri('/api/health').toString();
  String get authCheckUrl => _uri('/api/auth/check').toString();

  /// `GET /api/health` — no auth. Returns true when the server reports `ok`.
  Future<bool> health() async {
    final res = await _send(
      () => _http
          .get(
            _uri('/api/health'),
            headers: const {'Accept': 'application/json'},
          )
          .timeout(timeout),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res);
    }
    final body = _decodeObject(res);
    return body['ok'] == true;
  }

  /// `POST /api/auth/check` — verifies the bearer token. Throws [ApiException]
  /// (`code: unauthorized`) on 401, or another code on failure.
  Future<void> authCheck() async {
    final res = await _send(
      () => _http
          .post(_uri('/api/auth/check'), headers: _authHeaders)
          .timeout(timeout),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res);
    }
  }

  /// `GET /api/server/urls` — aggregated connection endpoints (v0.11).
  Future<ServerUrls> getServerUrls() async {
    final res = await _send(
      () => _http
          .get(_uri('/api/server/urls'), headers: _authHeaders)
          .timeout(timeout),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res);
    }
    return ServerUrls.fromJson(_decodeObject(res));
  }

  Future<ServerNotificationConfig?> getNotificationConfig() async {
    final res = await _send(
      () => _http
          .get(_uri('/api/server/status'), headers: _authHeaders)
          .timeout(timeout),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res);
    }
    final body = _decodeObject(res);
    final notifications = body['notifications'];
    if (notifications is Map<String, dynamic>) {
      return ServerNotificationConfig.fromJson(notifications);
    }
    return null;
  }

  Future<ServerNotificationConfig?> setNotificationPreview(
    String preview,
  ) async {
    final res = await _send(
      () => _http
          .patch(
            _uri('/api/server/notifications/preview'),
            headers: _jsonHeaders,
            body: jsonEncode({'preview': preview}),
          )
          .timeout(timeout),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res);
    }
    final body = _decodeObject(res);
    return ServerNotificationConfig.fromJson(body);
  }

  /// `POST /api/sync/now` — asks the server to run a lightweight foreground
  /// catch-up sync. The response is intentionally ignored by most callers; WS
  /// events and subsequent list/thread fetches carry the user-facing data.
  Future<int> syncNow() async {
    final res = await _send(
      () => _http
          .post(_uri('/api/sync/now'), headers: _authHeaders)
          .timeout(const Duration(seconds: 20)),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res);
    }
    final body = _decodeObject(res);
    final diagnostics = body['diagnostics'];
    if (diagnostics is Map<String, dynamic>) {
      int asInt(String key) =>
          diagnostics[key] is num ? (diagnostics[key] as num).toInt() : 0;
      return asInt('lastInsertedMessages') +
          asInt('lastUpdatePassCount') +
          asInt('lastUnsentCount');
    }
    return 0;
  }

  /// `GET /api/chats` — the chat list. Returns the `data` array decoded into
  /// [ChatSummary]. The optional `service`/`withArchived` query params default
  /// to the server's behaviour (iMessage, non-archived) unless provided.
  Future<List<ChatSummary>> getChats({
    String? service,
    bool? withArchived,
    int? limit,
    bool debug = false,
  }) async {
    final query = <String, String>{};
    if (service != null) query['service'] = service;
    if (withArchived != null) query['withArchived'] = '$withArchived';
    if (limit != null) query['limit'] = '$limit';
    if (debug) query['debug'] = 'true';
    final res = await _send(
      () => _http
          .get(_uri('/api/chats', query), headers: _authHeaders)
          .timeout(timeout),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res);
    }
    final body = _decodeObject(res);
    final data = body['data'];
    if (data is! List) {
      throw const ApiException(
        code: 'bad_response',
        message: 'Chat list response was not in the expected format.',
      );
    }
    return data
        .whereType<Map<String, dynamic>>()
        .map(ChatSummary.fromJson)
        .toList(growable: false);
  }

  /// `GET /api/messages/delta?since=<cursor>` — cursor catch-up (C21). Returns
  /// messages changed since the cursor (oldest-first), the affected chat GUIDs,
  /// the new cursor, and whether more remain. `since == null` seeds the cursor.
  Future<MessageDelta> fetchDelta({int? since, int limit = 200}) async {
    final res = await _send(
      () => _http
          .get(
            _uri('/api/messages/delta', {
              if (since != null) 'since': '$since',
              'limit': '$limit',
            }),
            headers: _authHeaders,
          )
          .timeout(timeout),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res);
    }
    final body = _decodeObject(res);
    final msgs =
        (body['messages'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(MessageModel.fromJson)
            .toList(growable: false) ??
        const <MessageModel>[];
    final guids =
        (body['chatGuids'] as List?)?.whereType<String>().toList(
          growable: false,
        ) ??
        const <String>[];
    return MessageDelta(
      messages: msgs,
      chatGuids: guids,
      cursor: (body['cursor'] as num?)?.toInt() ?? since ?? -1,
      hasMore: (body['hasMore'] as bool?) ?? false,
    );
  }

  Future<MessageActionCapabilities> getMessageActionCapabilities() async {
    final res = await _send(
      () => _http
          .get(
            _uri('/api/messages/actions/capabilities'),
            headers: _authHeaders,
          )
          .timeout(timeout),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res);
    }
    return MessageActionCapabilities.fromJson(_decodeObject(res));
  }

  Future<void> editMessage(
    String chatGuid,
    String messageGuid,
    String text, {
    int partIndex = 0,
  }) async {
    final chat = Uri.encodeComponent(chatGuid);
    final message = Uri.encodeComponent(messageGuid);
    final res = await _send(
      () => _http
          .post(
            _uri('/api/chats/$chat/messages/$message/edit'),
            headers: _jsonHeaders,
            body: jsonEncode({'text': text, 'partIndex': partIndex}),
          )
          .timeout(timeout),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res);
    }
  }

  Future<void> retractMessage(
    String chatGuid,
    String messageGuid, {
    int partIndex = 0,
  }) async {
    final chat = Uri.encodeComponent(chatGuid);
    final message = Uri.encodeComponent(messageGuid);
    final res = await _send(
      () => _http
          .post(
            _uri('/api/chats/$chat/messages/$message/retract'),
            headers: _jsonHeaders,
            body: jsonEncode({'partIndex': partIndex}),
          )
          .timeout(timeout),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res);
    }
  }

  Future<void> deleteMessage(String chatGuid, String messageGuid) async {
    final chat = Uri.encodeComponent(chatGuid);
    final message = Uri.encodeComponent(messageGuid);
    final res = await _send(
      () => _http
          .delete(
            _uri('/api/chats/$chat/messages/$message'),
            headers: _authHeaders,
          )
          .timeout(timeout),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res);
    }
  }

  /// `GET /api/chats/{guid}/messages` — message history for one chat. The
  /// server returns newest-first; callers reverse to chronological order.
  Future<List<MessageModel>> getMessages(
    String chatGuid, {
    int limit = 50,
    int offset = 0,
    bool includeEmpty = false,
  }) async {
    final res = await _send(
      () => _http
          .get(
            _uri('/api/chats/${Uri.encodeComponent(chatGuid)}/messages', {
              'limit': '$limit',
              'offset': '$offset',
              'includeEmpty': '$includeEmpty',
            }),
            headers: _authHeaders,
          )
          .timeout(timeout),
    );
    if (res.statusCode == 202) {
      final body = _decodeObject(res);
      throw ApiException(
        code: 'send_confirmation_timeout',
        message:
            (body['message'] as String?) ??
            'Message sent, but server confirmation is still pending.',
        statusCode: res.statusCode,
      );
    }
    if (res.statusCode != 200) {
      throw _errorFrom(res);
    }
    final data = _decodeObject(res)['data'];
    if (data is! List) {
      throw const ApiException(
        code: 'bad_response',
        message: 'Message list response was not in the expected format.',
      );
    }
    return data
        .whereType<Map<String, dynamic>>()
        .map(MessageModel.fromJson)
        .toList(growable: false);
  }

  /// `POST /api/chats/{guid}/send` — send plain text. Synchronous: the server
  /// waits until it confirms the outgoing row (or times out). Returns the
  /// confirmed [MessageModel]. [tempGuid] is the client correlation id.
  Future<MessageModel> sendText({
    required String chatGuid,
    required String tempGuid,
    required String message,
  }) async {
    final res = await _send(
      () => _http
          .post(
            _uri('/api/chats/${Uri.encodeComponent(chatGuid)}/send'),
            headers: {..._authHeaders, 'Content-Type': 'application/json'},
            body: jsonEncode({'tempGuid': tempGuid, 'message': message}),
          )
          // Send confirmation can take up to ~15s server-side.
          .timeout(const Duration(seconds: 20)),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res);
    }
    return MessageModel.fromJson(_decodeObject(res));
  }

  /// `GET /api/sync/settings` — the server's authoritative sync settings,
  /// including `allowSmsSend` (C20). Returns the flat settings map, or null on
  /// failure (the caller falls back to read-only behavior).
  Future<Map<String, dynamic>?> getSyncSettings() async {
    try {
      final res = await _send(
        () => _http
            .get(_uri('/api/sync/settings'), headers: _authHeaders)
            .timeout(const Duration(seconds: 10)),
      );
      if (res.statusCode != 200) return null;
      return _decodeObject(res);
    } catch (_) {
      return null;
    }
  }

  /// `PUT /api/sync/settings` — update the server settings. [settings] is the
  /// full settings map (the server replaces all fields). Returns the updated
  /// settings from the `{settings, diagnostics}` envelope, or null on failure.
  Future<Map<String, dynamic>?> putSyncSettings(
    Map<String, dynamic> settings,
  ) async {
    try {
      final res = await _send(
        () => _http
            .put(
              _uri('/api/sync/settings'),
              headers: {..._authHeaders, 'Content-Type': 'application/json'},
              body: jsonEncode(settings),
            )
            .timeout(const Duration(seconds: 15)),
      );
      if (res.statusCode != 200) return null;
      final body = _decodeObject(res);
      final updated = body['settings'];
      return updated is Map<String, dynamic> ? updated : null;
    } catch (_) {
      return null;
    }
  }

  /// `GET /api/sync/rules` — returns the server-authoritative muted chat GUIDs.
  /// The Flutter client no longer persists a local mute table; it mirrors these
  /// push rules in memory for UI state and local keep-alive notification gating.
  Future<Set<String>?> getMutedChatGuids() async {
    try {
      final res = await _send(
        () => _http
            .get(_uri('/api/sync/rules'), headers: _authHeaders)
            .timeout(const Duration(seconds: 10)),
      );
      if (res.statusCode != 200) return null;
      final rules = _decodeObject(res)['rules'];
      if (rules is! List) return <String>{};
      return {
        for (final rule in rules.whereType<Map<String, dynamic>>())
          if (rule['targetKind'] == 'chat' &&
              rule['pushMode'] == 'muted' &&
              (rule['targetValue'] as String?)?.trim().isNotEmpty == true)
            (rule['targetValue'] as String).trim(),
      };
    } catch (_) {
      return null;
    }
  }

  /// `PUT /api/sync/rules` — set a server-side sync/push rule. The client uses
  /// this only for notification mute parity: sync stays inherited, push is
  /// muted/inherited so Companion remains the main policy surface.
  Future<bool> putSyncRule({
    required String targetKind,
    required String targetValue,
    String syncMode = 'inherit',
    String pushMode = 'inherit',
  }) async {
    try {
      final res = await _send(
        () => _http
            .put(
              _uri('/api/sync/rules'),
              headers: {..._authHeaders, 'Content-Type': 'application/json'},
              body: jsonEncode({
                'targetKind': targetKind,
                'targetValue': targetValue,
                'syncMode': syncMode,
                'pushMode': pushMode,
              }),
            )
            .timeout(const Duration(seconds: 10)),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// `GET /api/test-contact` — current offline loopback test-contact settings.
  /// Returns null on any failure (the toggle then shows unavailable).
  Future<TestContactConfig?> getTestContactConfig() async {
    try {
      final res = await _send(
        () => _http
            .get(_uri('/api/test-contact'), headers: _authHeaders)
            .timeout(const Duration(seconds: 10)),
      );
      if (res.statusCode != 200) return null;
      return TestContactConfig.fromJson(_decodeObject(res));
    } catch (_) {
      return null;
    }
  }

  Future<bool?> getTestContactEnabled() async =>
      (await getTestContactConfig())?.enabled;

  /// `PUT /api/test-contact` — update the offline test contact. Returns the
  /// new config, or null on failure.
  Future<TestContactConfig?> setTestContact({bool? enabled}) async {
    try {
      final body = <String, Object?>{};
      if (enabled != null) body['enabled'] = enabled;
      final res = await _send(
        () => _http
            .put(
              _uri('/api/test-contact'),
              headers: {..._authHeaders, 'Content-Type': 'application/json'},
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 15)),
      );
      if (res.statusCode != 200) return null;
      return TestContactConfig.fromJson(_decodeObject(res));
    } catch (_) {
      return null;
    }
  }

  /// `PUT /api/test-contact` — turn the offline test contact on or off. Returns
  /// the new state, or null on failure.
  Future<bool?> setTestContactEnabled(bool enabled) async =>
      (await setTestContact(enabled: enabled))?.enabled;

  /// `POST /api/devices/register` — register this client so the server/Companion
  /// can show a connected device (C19). [body] is a small identity built by
  /// `buildDeviceRegistration`. Returns the server-assigned device id (echoed in
  /// `data.id`), or null on any failure (registration is best-effort).
  /// Registers this device. Returns the outcome ([status] 200 = ok; 0 = network
  /// error) so the caller can LOG failures rather than swallow them (C29b).
  Future<({String? id, int status, String? error})> registerDevice(
    Map<String, Object?> body,
  ) async {
    try {
      final res = await _send(
        () => _http
            .post(
              _uri('/api/devices/register'),
              headers: {..._authHeaders, 'Content-Type': 'application/json'},
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 10)),
      );
      if (res.statusCode != 200) {
        final snippet = res.body.trim();
        return (
          id: null,
          status: res.statusCode,
          error: snippet.isEmpty ? 'HTTP ${res.statusCode}' : snippet,
        );
      }
      final data = _decodeObject(res)['data'];
      return (
        id: data is Map<String, dynamic> ? data['id'] as String? : null,
        status: 200,
        error: null,
      );
    } on ApiException catch (e) {
      return (id: null, status: e.statusCode ?? 0, error: e.message);
    } catch (e) {
      return (id: null, status: 0, error: '$e');
    }
  }

  /// `GET /api/fcm/client` — the server's user-owned Firebase client config
  /// (C22), parsed from the admin's google-services.json. Returns the `data`
  /// map (`configured`, `projectId`, `appId`, `apiKey`, `messagingSenderId`,
  /// `storageBucket`) or null on failure. When `configured` is false the app
  /// stays on WebSocket + delta sync (Firebase is optional).
  Future<Map<String, dynamic>?> fetchFcmClientConfig() async {
    try {
      final res = await _send(
        () => _http
            .get(_uri('/api/fcm/client'), headers: _authHeaders)
            .timeout(const Duration(seconds: 10)),
      );
      if (res.statusCode != 200) return null;
      final data = _decodeObject(res)['data'];
      return data is Map<String, dynamic> ? data : null;
    } catch (_) {
      return null;
    }
  }

  /// `POST /api/devices/{id}/heartbeat` — refresh this device's last-seen time
  /// (C21u) so the server can report it as connected. Best-effort; failures are
  /// swallowed (the device simply goes stale → disconnected).
  Future<void> deviceHeartbeat(String id) async {
    try {
      await _send(
        () => _http
            .post(
              _uri('/api/devices/${Uri.encodeComponent(id)}/heartbeat'),
              headers: _authHeaders,
            )
            .timeout(const Duration(seconds: 10)),
      );
    } catch (_) {
      // Ignore — presence is derived from freshness, not from this call.
    }
  }

  /// `POST /api/chats/{guid}/send-attachment` — send a file to an iMessage chat
  /// (C19). multipart/form-data with `file` + `tempGuid`. The server replies
  /// 202 optimistically; the real attachment row arrives via sync/WS. Throws
  /// [ApiException] on any non-2xx (e.g. 400 for a non-iMessage chat).
  Future<void> sendAttachment({
    required String chatGuid,
    required String tempGuid,
    required Uint8List bytes,
    required String filename,
    bool isAudioMessage = false,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      _uri('/api/chats/${Uri.encodeComponent(chatGuid)}/send-attachment'),
    );
    request.headers.addAll(_authHeaders);
    request.fields['tempGuid'] = tempGuid;
    if (isAudioMessage) {
      request.fields['isAudioMessage'] = 'true';
    }
    request.files.add(
      http.MultipartFile.fromBytes('file', bytes, filename: filename),
    );

    final http.Response res;
    try {
      final streamed = await _http
          .send(request)
          .timeout(const Duration(seconds: 60));
      res = await http.Response.fromStream(streamed);
    } on TimeoutException {
      throw const ApiException(
        code: 'timeout',
        message: 'Attachment send timed out',
      );
    } catch (e) {
      throw ApiException(code: 'network_error', message: '$e');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw _errorFrom(res);
    }
  }

  /// `POST /api/chats/{guid}/send-attachments` — send several files as a single
  /// grouped media send when the paired backend supports the batch endpoint.
  Future<void> sendAttachmentBatch({
    required String chatGuid,
    required String tempGuid,
    required List<({Uint8List bytes, String filename})> files,
  }) async {
    if (files.isEmpty) return;
    final request = http.MultipartRequest(
      'POST',
      _uri('/api/chats/${Uri.encodeComponent(chatGuid)}/send-attachments'),
    );
    request.headers.addAll(_authHeaders);
    request.fields['tempGuid'] = tempGuid;
    for (final file in files) {
      request.files.add(
        http.MultipartFile.fromBytes(
          'files',
          file.bytes,
          filename: file.filename,
        ),
      );
    }

    final http.Response res;
    try {
      final streamed = await _http
          .send(request)
          .timeout(const Duration(seconds: 90));
      res = await http.Response.fromStream(streamed);
    } on TimeoutException {
      throw const ApiException(
        code: 'timeout',
        message: 'Attachment batch send timed out',
      );
    } catch (e) {
      throw ApiException(code: 'network_error', message: '$e');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw _errorFrom(res);
    }
  }

  /// `GET /api/attachments/{guid}` — raw attachment bytes (authenticated).
  Future<Uint8List> getAttachmentBytes(String attachmentGuid) async {
    final res = await _send(
      () => _http
          .get(
            _uri('/api/attachments/${Uri.encodeComponent(attachmentGuid)}'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 30)),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res);
    }
    return res.bodyBytes;
  }

  Future<Uint8List> getAttachmentPreviewBytes(
    AttachmentModel attachment,
  ) async {
    final preview = attachment.previewUrl;
    if (preview == null || preview.isEmpty) {
      return getAttachmentBytes(attachment.guid);
    }
    final path = preview.startsWith('/') ? preview : '/$preview';
    final res = await _send(
      () => _http
          .get(_uri(path), headers: {'Authorization': 'Bearer $token'})
          .timeout(const Duration(seconds: 30)),
    );
    if (res.statusCode != 200) {
      if (attachment.isStickerLike) {
        return getAttachmentBytes(attachment.guid);
      }
      throw _errorFrom(res);
    }
    return res.bodyBytes;
  }

  /// Absolute URL for an attachment, for media players that stream by URL.
  /// Pair it with [mediaAuthHeaders] so the token travels in the header, not
  /// the URL.
  String attachmentUrl(String attachmentGuid) => _uri(
    '/api/attachments/${Uri.encodeComponent(attachmentGuid)}',
  ).toString();

  String attachmentPlayableUrl(String attachmentGuid) => _uri(
    '/api/attachments/${Uri.encodeComponent(attachmentGuid)}/playable',
  ).toString();

  /// Authorization headers for streaming media (e.g. just_audio). Kept out of
  /// the URL so the token isn't logged by proxies.
  Map<String, String> get mediaAuthHeaders => {
    'Authorization': 'Bearer $token',
  };

  void close() => _http.close();

  // --- internals -------------------------------------------------------------

  Future<http.Response> _send(Future<http.Response> Function() run) async {
    try {
      return await run();
    } on TimeoutException {
      throw const ApiException(
        code: 'timeout',
        message: 'The server did not respond in time.',
      );
    } catch (e) {
      throw ApiException(
        code: 'network_error',
        message: 'Could not reach the server: $e',
      );
    }
  }

  Map<String, dynamic> _decodeObject(http.Response res) {
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map<String, dynamic>) return decoded;
      throw const FormatException('expected a JSON object');
    } catch (_) {
      throw ApiException(
        code: 'bad_response',
        message: 'The server returned an unexpected response.',
        statusCode: res.statusCode,
      );
    }
  }

  /// Builds an [ApiException] from a non-2xx response, parsing the standard
  /// `{"error":{"code","message"}}` envelope when present.
  ApiException _errorFrom(http.Response res) {
    String code = 'http_${res.statusCode}';
    String message = 'Request failed (HTTP ${res.statusCode}).';
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map<String, dynamic> &&
          decoded['error'] is Map<String, dynamic>) {
        final err = decoded['error'] as Map<String, dynamic>;
        code = (err['code'] as String?) ?? code;
        message = (err['message'] as String?) ?? message;
      }
    } catch (_) {
      // Non-JSON body; keep the generic HTTP message.
    }
    return ApiException(
      code: code,
      message: message,
      statusCode: res.statusCode,
    );
  }
}
