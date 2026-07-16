import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mica_go/core/network/api_client.dart';
import 'package:mica_go/features/chats/attachment_panel.dart';
import 'package:mica_go/features/chats/chat_service.dart';
import 'package:mica_go/features/chats/models/chat_summary.dart';
import 'package:mica_go/features/chats/models/message_model.dart';

void main() {
  group('C21c explicit server send capabilities (no client inference)', () {
    test('server canSendText/Attachments win over local derivation', () {
      // Server says SMS chat but explicitly allows sending (e.g. SMS enabled).
      final c = ChatSummary.fromJson({
        'guid': 'SMS;-;+1555',
        'serviceName': 'SMS',
        'effectiveService': 'sms',
        'canSendText': true,
        'canSendAttachments': true,
      });
      // Even with the local SMS setting OFF, the explicit server cap wins.
      expect(c.canSendText(allowSmsSend: false), isTrue);
      expect(c.canSendAttachments(allowSmsSend: false), isTrue);
    });

    test('phone-number iMessage chat: text + attachments enabled', () {
      final c = ChatSummary.fromJson({
        'guid': 'any;-;+8618083772301',
        'chatIdentifier': '+8618083772301',
        'effectiveService': 'imessage',
        'canSendText': true,
        'canSendAttachments': true,
      });
      expect(c.service, ChatService.imessage);
      expect(c.canSendText(allowSmsSend: false), isTrue);
      expect(c.canSendAttachments(allowSmsSend: false), isTrue);
    });

    test('unknown: explicit caps false → read-only', () {
      final c = ChatSummary.fromJson({
        'guid': 'g',
        'effectiveService': 'unknown',
        'canSendText': false,
        'canSendAttachments': false,
      });
      expect(c.canSendText(allowSmsSend: true), isFalse);
      expect(c.canSendAttachments(allowSmsSend: true), isFalse);
    });

    test('text and attachment gates share the same source', () {
      final c = ChatSummary.fromJson({
        'guid': 'g',
        'effectiveService': 'imessage',
        'canSendText': true,
        'canSendAttachments': true,
      });
      expect(
        c.canSendText(allowSmsSend: false),
        c.canSendAttachments(allowSmsSend: false),
      );
    });

    test('older server (no caps) falls back to service + setting', () {
      final imsg = ChatSummary.fromJson({
        'guid': 'g',
        'effectiveService': 'imessage',
      });
      expect(imsg.canSendText(allowSmsSend: false), isTrue);
      final sms = ChatSummary.fromJson({
        'guid': 'g',
        'effectiveService': 'sms',
      });
      expect(sms.canSendText(allowSmsSend: false), isFalse);
      expect(sms.canSendText(allowSmsSend: true), isTrue);
    });
  });

  group('staged attachment + multi-send', () {
    test('StagedAttachment image detection by extension', () {
      Uint8List b() => Uint8List.fromList([1]);
      expect(StagedAttachment(bytes: b(), filename: 'a.JPG').isImage, isTrue);
      expect(StagedAttachment(bytes: b(), filename: 'a.png').isImage, isTrue);
      expect(StagedAttachment(bytes: b(), filename: 'a.mp4').isImage, isFalse);
      expect(
        StagedAttachment(bytes: b(), filename: 'doc.pdf').isImage,
        isFalse,
      );
    });

    test('gallery picks carry a sourceId for multi-select toggling', () {
      final g = StagedAttachment(
        bytes: Uint8List.fromList([1]),
        filename: 'IMG.jpg',
        sourceId: 'asset-42',
      );
      expect(g.sourceId, 'asset-42');
      // Camera/file picks have no sourceId (not toggleable from the grid).
      final f = StagedAttachment(
        bytes: Uint8List.fromList([1]),
        filename: 'd.pdf',
      );
      expect(f.sourceId, isNull);
    });

    test('multiple images each post to the send-attachment route', () async {
      final paths = <String>[];
      final mock = MockClient((req) async {
        paths.add(req.url.path);
        return http.Response('{"state":"sent_unconfirmed"}', 202);
      });
      final api = ApiClient(
        baseUrl: 'http://127.0.0.1:3000',
        token: 'tok',
        httpClient: mock,
      );
      for (final name in ['a.jpg', 'b.jpg', 'c.png']) {
        await api.sendAttachment(
          chatGuid: 'iMessage;-;+1',
          tempGuid: 't-$name',
          bytes: Uint8List.fromList(utf8.encode(name)),
          filename: name,
        );
      }
      expect(paths.length, 3);
      expect(paths.every((p) => p.endsWith('/send-attachment')), isTrue);
    });
  });

  group('attachment thumbnail transport', () {
    test('inline thumbnail requests the bounded preview variant', () async {
      Uri? requested;
      final api = ApiClient(
        baseUrl: 'http://127.0.0.1:3000',
        token: 'tok',
        httpClient: MockClient((request) async {
          requested = request.url;
          return http.Response.bytes([1, 2, 3], 200);
        }),
      );
      const attachment = AttachmentModel(
        guid: 'photo-guid',
        downloadUrl: '/api/attachments/photo-guid',
        attachmentKind: 'image',
      );

      await api.getAttachmentThumbnailBytes(attachment);

      expect(requested?.path, '/api/attachments/photo-guid/preview');
      expect(requested?.queryParameters['thumbnail'], '1');
    });

    test('original attachment request remains separate', () async {
      Uri? requested;
      final api = ApiClient(
        baseUrl: 'http://127.0.0.1:3000',
        token: 'tok',
        httpClient: MockClient((request) async {
          requested = request.url;
          return http.Response.bytes([1, 2, 3], 200);
        }),
      );

      await api.getAttachmentBytes('photo-guid');

      expect(requested?.path, '/api/attachments/photo-guid');
      expect(requested?.query, isEmpty);
    });
  });
}
