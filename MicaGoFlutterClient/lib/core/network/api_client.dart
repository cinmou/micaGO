import 'secure_transport.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../features/chats/models/chat_summary.dart';
import '../../features/chats/models/message_model.dart';
import '../models/server_urls.dart';
import '../l10n/app_localizations.dart';
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

class MessageHistoryPage {
  final List<MessageModel> messages;
  final String? nextCursor;
  final bool hasMore;
  const MessageHistoryPage(this.messages, this.nextCursor, this.hasMore);
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
  LocalSendState get sendState => code == 'send_confirmation_timeout'
      ? LocalSendState.sentUnconfirmed
      : const {'timeout', 'network_error', 'bad_response'}.contains(code) ||
            const {502, 503, 504}.contains(statusCode)
      ? LocalSendState.pending
      : LocalSendState.failed;
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

  String localizedMessage({bool forMessages = false}) {
    final strings = MicaLocalizations.current;
    return switch (code) {
      'unauthorized' => strings.t('error.tokenRejected'),
      'timeout' => strings.t(
        forMessages ? 'error.timeoutMessages' : 'error.timeoutChats',
      ),
      'network_error' => strings.t('error.unreachable'),
      'not_found' when forMessages => strings.t('error.chatNotFound'),
      _ => message,
    };
  }

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

/// C63: a MultipartRequest that reports upload progress as its body stream is
/// consumed by the HTTP client — this is what drives the progress bar in the
/// optimistic attachment bubble. Progress is byte-accurate for the whole
/// multipart body (the file dominates it).
class _ProgressMultipartRequest extends http.MultipartRequest {
  final void Function(int sent, int total)? onProgress;

  _ProgressMultipartRequest(super.method, super.url, {this.onProgress});

  @override
  http.ByteStream finalize() {
    final inner = super.finalize();
    final report = onProgress;
    if (report == null) return inner;
    final total = contentLength;
    var sent = 0;
    return http.ByteStream(
      inner.transform(
        StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (chunk, sink) {
            sent += chunk.length;
            report(sent, total);
            sink.add(chunk);
          },
        ),
      ),
    );
  }
}

/// Authenticated REST and media access. Credentials travel in headers.
class ApiClient {
  final String baseUrl;
  final String token;
  final String? tlsFingerprint;
  final http.Client _http;
  final Duration timeout;

  ApiClient({
    required this.baseUrl,
    required this.token,
    this.tlsFingerprint,
    http.Client? httpClient,
    void Function()? onUnauthorized,
    this.timeout = const Duration(seconds: 12),
  }) : _http = _AuthObservingClient(
         httpClient ?? secureHttpClient(baseUrl, fingerprint: tlsFingerprint),
         onUnauthorized,
       );

  Future<Map<String, dynamic>> redeemPairingCode(String code) async {
    final response = await _request(
      'POST',
      _uri('/api/pairing/redeem'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'pairingCode': code}),
    );

    return _decodeObject(response);
  }

  /// Native media decoders cannot use Dart TLS callbacks. Download through the
  /// same authenticated, pinned client, then hand the verified file to them.
  Future<File> downloadPlayableFile(String guid) async {
    final directory = await getTemporaryDirectory();
    final file = File(
      '${directory.path}/micago-playable-${DateTime.now().microsecondsSinceEpoch}',
    );
    final response = await _transport(
      () => _http.send(
        http.Request(
          'GET',
          _uri('/api/attachments/${Uri.encodeComponent(guid)}/playable'),
        )..headers.addAll(_authHeaders),
      ),
      timeout,
    );
    if (response.statusCode != 200) {
      throw _errorFrom(
        await _transport(() => http.Response.fromStream(response), timeout),
      );
    }
    final sink = file.openWrite();
    try {
      await _transport(
        () => response.stream.timeout(const Duration(seconds: 30)).pipe(sink),
        const Duration(seconds: 30),
      );
      return file;
    } catch (_) {
      await sink.close();
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse('${normalizeBaseUrl(baseUrl)}$path');
    if (query == null || query.isEmpty) return base;
    return base.replace(queryParameters: {...base.queryParameters, ...query});
  }

  Future<Map<String, dynamic>> getChatPreferences() =>
      _requestObject('GET', '/api/chat-preferences');
  Future<Map<String, dynamic>> patchChatPreferences(
    Map<String, dynamic> mutation,
  ) => _requestObject('PATCH', '/api/chat-preferences', body: mutation);

  Future<Map<String, dynamic>> getReadState() =>
      _requestObject('GET', '/api/read-state');
  Future<Map<String, dynamic>> patchReadState(Map<String, dynamic> mutation) =>
      _requestObject('PATCH', '/api/read-state', body: mutation);

  Future<Map<String, dynamic>> getMessagePreferences() =>
      _requestObject('GET', '/api/message-preferences');
  Future<Map<String, dynamic>> patchMessagePreferences(
    Map<String, dynamic> mutation,
  ) => _requestObject('PATCH', '/api/message-preferences', body: mutation);

  Map<String, String> get _authHeaders => {
    'Authorization': 'Bearer $token',
    'Accept': 'application/json',
  };
  Map<String, String> get _jsonHeaders => {
    ..._authHeaders,
    'Content-Type': 'application/json',
  };

  /// `GET /api/health` — no auth. Returns true when the server reports `ok`.
  Future<bool> health() async {
    final res = await _request(
      'GET',
      _uri('/api/health'),
      headers: const {'Accept': 'application/json'},
    );

    final body = _decodeObject(res);
    return body['ok'] == true;
  }

  /// `POST /api/auth/check` — verifies the bearer token. Throws [ApiException]
  /// (`code: unauthorized`) only for a structured micaGO rejection.
  Future<void> authCheck() async {
    await _request('POST', _uri('/api/auth/check'));
  }

  /// `GET /api/server/urls` — aggregated connection endpoints (v0.11).
  Future<ServerUrls> getServerUrls() async {
    final res = await _request('GET', _uri('/api/server/urls'));

    return ServerUrls.fromJson(_decodeObject(res));
  }

  Future<ServerNotificationConfig?> getNotificationConfig() async {
    final res = await _request('GET', _uri('/api/server/status'));

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
    final res = await _request(
      'PATCH',
      _uri('/api/server/notifications/preview'),
      headers: _jsonHeaders,
      body: jsonEncode({'preview': preview}),
    );

    final body = _decodeObject(res);
    return ServerNotificationConfig.fromJson(body);
  }

  /// `POST /api/sync/now` — asks the server to run a lightweight foreground
  /// catch-up sync. The response is intentionally ignored by most callers; WS
  /// events and subsequent list/thread fetches carry the user-facing data.
  Future<int> syncNow() async {
    final res = await _request(
      'POST',
      _uri('/api/sync/now'),
      requestTimeout: const Duration(seconds: 20),
    );

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
    final res = await _request('GET', _uri('/api/chats', query));

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
    final res = await _request(
      'GET',
      _uri('/api/messages/delta', {
        if (since != null) 'since': '$since',
        'limit': '$limit',
      }),
    );

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
    final res = await _request(
      'GET',
      _uri('/api/messages/actions/capabilities'),
    );

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
    await _request(
      'POST',
      _uri('/api/chats/$chat/messages/$message/edit'),
      headers: _jsonHeaders,
      body: jsonEncode({'text': text, 'partIndex': partIndex}),
    );
  }

  Future<void> retractMessage(
    String chatGuid,
    String messageGuid, {
    int partIndex = 0,
  }) async {
    final chat = Uri.encodeComponent(chatGuid);
    final message = Uri.encodeComponent(messageGuid);
    await _request(
      'POST',
      _uri('/api/chats/$chat/messages/$message/retract'),
      headers: _jsonHeaders,
      body: jsonEncode({'partIndex': partIndex}),
    );
  }

  Future<void> deleteMessage(String chatGuid, String messageGuid) async {
    final chat = Uri.encodeComponent(chatGuid);
    final message = Uri.encodeComponent(messageGuid);
    await _request('DELETE', _uri('/api/chats/$chat/messages/$message'));
  }

  Future<MessageHistoryPage> getMessageHistory(
    Iterable<String> routes, {
    int limit = 50,
    String? before,
  }) async {
    final uri = _uri('/api/messages/history').replace(
      queryParameters: {
        'chatGuid': routes.toSet().toList(),
        'limit': '$limit',
        'before': ?before,
      },
    );
    final response = await _request('GET', uri);

    final body = _decodeObject(response);
    final rows = body['data'];
    if (rows is! List || body['hasMore'] is! bool) {
      throw const ApiException(
        code: 'bad_response',
        message: 'Invalid message history response',
      );
    }
    final cursor = body['nextCursor'] as String?;
    final hasMore = body['hasMore'] as bool;
    if (hasMore && (cursor == null || cursor.isEmpty)) {
      throw const ApiException(
        code: 'bad_response',
        message: 'Missing message history cursor',
      );
    }
    return MessageHistoryPage(
      rows
          .whereType<Map<String, dynamic>>()
          .map(MessageModel.fromJson)
          .toList(growable: false),
      cursor,
      hasMore,
    );
  }

  /// `POST /api/chats/{guid}/send` — send plain text. Synchronous: the server
  /// waits until it confirms the outgoing row (or times out). Returns the
  /// confirmed [MessageModel]. [tempGuid] is the client correlation id.
  Future<MessageModel> sendText({
    required String chatGuid,
    required String tempGuid,
    required String message,
  }) async {
    final res = await _request(
      'POST',
      _uri('/api/chats/${Uri.encodeComponent(chatGuid)}/send'),
      headers: _jsonHeaders,
      body: jsonEncode({'tempGuid': tempGuid, 'message': message}),
      requestTimeout: const Duration(seconds: 20),
      accepted: const {200, 202},
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

    final confirmed = MessageModel.fromJson(_decodeObject(res));
    if (confirmed.guid.isEmpty) {
      throw const ApiException(
        code: 'bad_response',
        message: 'Missing send confirmation.',
      );
    }
    return confirmed;
  }

  Future<Map<String, dynamic>> getSyncSettings() =>
      _requestObject('GET', '/api/sync/settings');

  /// The server replaces the full settings map.
  Future<Map<String, dynamic>> putSyncSettings(
    Map<String, dynamic> settings,
  ) async {
    final body = await _requestObject(
      'PUT',
      '/api/sync/settings',
      body: settings,
    );
    return _objectField(body, 'settings');
  }

  Future<Set<String>> getMutedChatGuids() async {
    final body = await _requestObject('GET', '/api/sync/rules');
    final rules = body['rules'];
    if (rules is! List) {
      throw const ApiException(
        code: 'bad_response',
        message: 'Invalid sync rules response.',
      );
    }
    return {
      for (final rule in rules.cast<Map<String, dynamic>>())
        if (rule['targetKind'] == 'chat' &&
            rule['pushMode'] == 'muted' &&
            (rule['targetValue'] as String?)?.trim().isNotEmpty == true)
          (rule['targetValue'] as String).trim(),
    };
  }

  Future<void> putSyncRule({
    required String targetKind,
    required String targetValue,
    String syncMode = 'inherit',
    String pushMode = 'inherit',
  }) async {
    await _requestObject(
      'PUT',
      '/api/sync/rules',
      body: {
        'targetKind': targetKind,
        'targetValue': targetValue,
        'syncMode': syncMode,
        'pushMode': pushMode,
      },
    );
  }

  Future<TestContactConfig> getTestContactConfig() async =>
      TestContactConfig.fromJson(
        await _requestObject('GET', '/api/test-contact'),
      );

  Future<TestContactConfig> setTestContact({bool? enabled}) async =>
      TestContactConfig.fromJson(
        await _requestObject(
          'PUT',
          '/api/test-contact',
          body: {'enabled': ?enabled},
        ),
      );

  /// Registers device identity and returns a diagnostic outcome for background callers.
  Future<({String? id, int status, String? error})> registerDevice(
    Map<String, Object?> body,
  ) async {
    try {
      final res = await _request(
        'POST',
        _uri('/api/devices/register'),
        headers: _jsonHeaders,
        body: jsonEncode(body),
        requestTimeout: const Duration(seconds: 10),
      );
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

  /// Optional Firebase configuration; `configured: false` is a successful response.
  Future<Map<String, dynamic>> fetchFcmClientConfig() async =>
      _objectField(await _requestObject('GET', '/api/fcm/client'), 'data');

  Future<void> deviceHeartbeat(String id) async {
    await _request(
      'POST',
      _uri('/api/devices/${Uri.encodeComponent(id)}/heartbeat'),
    );
  }

  /// `POST /api/chats/{guid}/send-attachment` — send a file to an iMessage chat
  /// (C19). multipart/form-data with `file` + `tempGuid`. The server replies
  /// 202 optimistically; the real attachment row arrives via sync/WS. Throws
  /// [ApiException] on any non-2xx (e.g. 400 for a non-iMessage chat).
  ///
  /// C63: [onSendProgress] reports uploaded/total bytes for the optimistic
  /// bubble's progress bar. Returns the filename the server will actually send
  /// (voice notes get converted server-side), for pending-row reconciliation.
  Future<String?> sendAttachment({
    required String chatGuid,
    required String tempGuid,
    Uint8List? bytes,
    String? filePath,
    required String filename,
    bool isAudioMessage = false,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    final request = _ProgressMultipartRequest(
      'POST',
      _uri('/api/chats/${Uri.encodeComponent(chatGuid)}/send-attachment'),
      onProgress: onSendProgress,
    );
    request.headers.addAll(_authHeaders);
    request.fields['tempGuid'] = tempGuid;
    if (isAudioMessage) {
      request.fields['isAudioMessage'] = 'true';
    }
    if ((bytes == null) == (filePath == null)) {
      throw ArgumentError('Provide exactly one attachment source');
    }
    request.files.add(
      filePath != null
          ? await http.MultipartFile.fromPath(
              'file',
              filePath,
              filename: filename,
            )
          : http.MultipartFile.fromBytes('file', bytes!, filename: filename),
    );

    final streamed = await _transport(
      () => _http.send(request),
      const Duration(seconds: 60),
    );
    final res = await _transport(
      () => http.Response.fromStream(streamed),
      const Duration(seconds: 30),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw _errorFrom(res);
    }
    try {
      final body = jsonDecode(res.body);
      if (body is Map<String, dynamic>) return body['filename'] as String?;
    } catch (_) {}
    return null;
  }

  /// `GET /api/attachments/{guid}` — raw attachment bytes (authenticated).
  Future<Uint8List> getAttachmentBytes(String attachmentGuid) async {
    final res = await _request(
      'GET',
      _uri('/api/attachments/${Uri.encodeComponent(attachmentGuid)}'),
      headers: {'Authorization': 'Bearer $token'},
      requestTimeout: const Duration(seconds: 30),
    );

    return res.bodyBytes;
  }

  Future<Uint8List> getAttachmentPreviewBytes(
    AttachmentModel attachment,
  ) async {
    final path =
        '/api/attachments/${Uri.encodeComponent(attachment.guid)}/preview';
    final res = await _request(
      'GET',
      _uri(path),
      headers: {'Authorization': 'Bearer $token'},
      requestTimeout: const Duration(seconds: 30),
    );

    return res.bodyBytes;
  }

  /// A bounded preview for scrolling surfaces. The full-screen viewer keeps
  /// using [getAttachmentPreviewBytes], which returns original bytes for
  /// directly renderable images and an orientation-correct high-quality
  /// rendering for Apple-only formats.
  Future<Uint8List> getAttachmentThumbnailBytes(
    AttachmentModel attachment,
  ) async {
    final path =
        '/api/attachments/${Uri.encodeComponent(attachment.guid)}/preview';
    final uri = _uri(path).replace(queryParameters: {'thumbnail': '1'});
    final res = await _request(
      'GET',
      uri,
      headers: {'Authorization': 'Bearer $token'},
      requestTimeout: const Duration(seconds: 30),
    );

    return res.bodyBytes;
  }

  void close() => _http.close();

  // --- internals -------------------------------------------------------------

  Future<http.Response> _request(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    String? body,
    Duration? requestTimeout,
    Set<int> accepted = const {200},
  }) async {
    final response = await _transport(() async {
      final request = http.Request(method, uri)
        ..headers.addAll(headers ?? _authHeaders);
      if (body != null) request.body = body;
      return http.Response.fromStream(await _http.send(request));
    }, requestTimeout ?? timeout);
    if (!accepted.contains(response.statusCode)) throw _errorFrom(response);
    return response;
  }

  Future<Map<String, dynamic>> _requestObject(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async => _decodeObject(
    await _request(
      method,
      _uri(path),
      headers: body == null ? _authHeaders : _jsonHeaders,
      body: body == null ? null : jsonEncode(body),
    ),
  );

  Map<String, dynamic> _objectField(Map<String, dynamic> body, String field) {
    final value = body[field];
    if (value is Map<String, dynamic>) return value;
    throw const ApiException(
      code: 'bad_response',
      message: 'Invalid server response.',
    );
  }

  Future<T> _transport<T>(Future<T> Function() run, Duration duration) async {
    try {
      return await run().timeout(duration);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException(
        code: 'timeout',
        message: 'The server did not respond in time.',
      );
    } on http.ClientException catch (e) {
      throw ApiException(
        code: 'network_error',
        message: 'Could not reach the server: $e',
      );
    } on IOException catch (e) {
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

/// Observe all authenticated REST/media/upload responses, including streams.
class _AuthObservingClient extends http.BaseClient {
  final http.Client inner;
  final void Function()? onUnauthorized;
  _AuthObservingClient(this.inner, this.onUnauthorized);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await inner.send(request);
    if (response.statusCode == 401 &&
        request.headers['Authorization']?.isNotEmpty == true) {
      // A proxy's login page is not evidence that micaGO revoked a device.
      // Bound the error body; this response will not be handed to a caller.
      final body = <int>[];
      await for (final chunk in response.stream) {
        if (body.length + chunk.length > 4096) break;
        body.addAll(chunk);
      }
      var rejected = false;
      try {
        final decoded = jsonDecode(utf8.decode(body));
        rejected =
            decoded is Map<String, dynamic> &&
            decoded['error'] is Map &&
            decoded['error']['code'] == 'unauthorized';
      } on FormatException {
        // Non-micaGO 401: preserve the pairing and report a route failure.
      }
      if (rejected) onUnauthorized?.call();
      throw ApiException(
        code: rejected ? 'unauthorized' : 'http_401',
        message: rejected
            ? 'Device token rejected.'
            : 'The connection endpoint refused access.',
        statusCode: 401,
      );
    }
    return response;
  }

  @override
  void close() => inner.close();
}
