import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mica_go/core/network/api_client.dart';
import 'package:mica_go/features/chats/chat_service.dart';
import 'package:mica_go/features/chats/models/chat_summary.dart';

void main() {
  group('attachment send gating (server-authoritative service)', () {
    // The composer enables attachment send only when the chat is sendable.
    // Sendability comes solely from ChatService — never the GUID/handle shape.
    test('iMessage chat (incl. phone-number/any;-;) allows attachments', () {
      final c = ChatSummary.fromJson({
        'guid': 'any;-;+8618083772301',
        'chatIdentifier': '+8618083772301',
        'serviceName': 'iMessage',
        'serviceCategory': 'imessage',
      });
      expect(c.service.canSendWith(allowSmsSend: false), isTrue);
    });

    test('SMS and Unknown chats do not allow attachments', () {
      final sms = ChatSummary.fromJson({
        'guid': 'SMS;-;+1555',
        'serviceName': 'SMS',
        'serviceCategory': 'sms',
      });
      final unknown = ChatSummary.fromJson({
        'guid': 'x',
        'chatIdentifier': 'x',
      });
      expect(sms.service.canSendWith(allowSmsSend: false), isFalse);
      expect(unknown.service.canSendWith(allowSmsSend: false), isFalse);
    });
  });

  group('ApiClient.sendAttachment request shape', () {
    test(
      'posts multipart with file + tempGuid to the send-attachment route',
      () async {
        // MockClient finalizes the MultipartRequest into a plain Request, so we
        // assert on the finalized form (method, url, content-type, body, header).
        late http.Request captured;
        final mock = MockClient((req) async {
          captured = req;
          return http.Response('{"state":"sent_unconfirmed"}', 202);
        });
        final api = ApiClient(
          baseUrl: 'http://127.0.0.1:3000',
          token: 'tok',
          httpClient: mock,
        );

        await api.sendAttachment(
          chatGuid: 'any;-;+8618083772301',
          tempGuid: 'tmp-1',
          bytes: Uint8List.fromList(utf8.encode('hello-bytes')),
          filename: 'photo.jpg',
        );

        expect(captured.method, 'POST');
        expect(
          captured.url.path,
          '/api/chats/${Uri.encodeComponent('any;-;+8618083772301')}/send-attachment',
        );
        expect(
          captured.headers['content-type'],
          contains('multipart/form-data'),
        );
        expect(captured.headers['Authorization'], 'Bearer tok');
        // The multipart body carries the tempGuid field, the file field, the
        // filename, and the bytes.
        expect(captured.body, contains('name="tempGuid"'));
        expect(captured.body, contains('tmp-1'));
        expect(captured.body, contains('name="file"'));
        expect(captured.body, contains('filename="photo.jpg"'));
        expect(captured.body, contains('hello-bytes'));
      },
    );

    test(
      'voice messages include the BlueBubbles-style isAudioMessage flag',
      () async {
        late http.Request captured;
        final mock = MockClient((req) async {
          captured = req;
          return http.Response('{"state":"sent_unconfirmed"}', 202);
        });
        final api = ApiClient(
          baseUrl: 'http://127.0.0.1:3000',
          token: 'tok',
          httpClient: mock,
        );

        await api.sendAttachment(
          chatGuid: 'any;-;+8618083772301',
          tempGuid: 'tmp-voice',
          bytes: Uint8List.fromList([1, 2, 3]),
          filename: 'voice_1782663292267.m4a',
          isAudioMessage: true,
        );

        expect(captured.body, contains('name="isAudioMessage"'));
        expect(captured.body, contains('true'));
      },
    );

    test('non-2xx (e.g. 400 SMS chat) throws ApiException', () async {
      final mock = MockClient((req) async {
        return http.Response(
          '{"error":{"code":"bad_request","message":"attachments can only be sent to iMessage chats"}}',
          400,
        );
      });
      final api = ApiClient(
        baseUrl: 'http://127.0.0.1:3000',
        token: 'tok',
        httpClient: mock,
      );

      expect(
        () => api.sendAttachment(
          chatGuid: 'SMS;-;+1555',
          tempGuid: 'tmp-2',
          bytes: Uint8List.fromList([1, 2, 3]),
          filename: 'x.txt',
        ),
        throwsA(isA<ApiException>()),
      );
    });
  });
}
