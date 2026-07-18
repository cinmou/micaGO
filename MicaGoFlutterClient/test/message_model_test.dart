import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/features/chats/models/message_model.dart';

void main() {
  group('MessageModel.fromJson', () {
    test('dedupes duplicate attachment records for the same file (C49)', () {
      // chat.db can carry several attachment rows (DISTINCT guids) for one file;
      // dedup by file identity (name+size+type), not just guid, so a photo/file/
      // sticker/voice clip never renders twice. Genuinely different files stay.
      final m = MessageModel.fromJson({
        'guid': 'm1',
        'isFromMe': false,
        'attachments': [
          // Same file, different guids → one of these survives.
          {
            'guid': 'att-1',
            'transferName': 'IMG_001.HEIC',
            'totalBytes': 12345,
            'mimeType': 'image/heic',
            'downloadUrl': '/a',
          },
          {
            'guid': 'att-2',
            'transferName': 'IMG_001.HEIC',
            'totalBytes': 12345,
            'mimeType': 'image/heic',
            'downloadUrl': '/b',
          },
          // A different file → kept.
          {
            'guid': 'att-3',
            'transferName': 'voice.m4a',
            'totalBytes': 999,
            'mimeType': 'audio/m4a',
            'downloadUrl': '/c',
          },
        ],
      });
      expect(m.attachments.length, 2);
      expect(m.attachments.map((a) => a.transferName), [
        'IMG_001.HEIC',
        'voice.m4a',
      ]);
    });

    test('parses core fields and handle', () {
      final m = MessageModel.fromJson({
        'guid': 'p:0/ABC',
        'text': 'Hello',
        'service': 'iMessage',
        'dateCreated': 1717372800000,
        'isFromMe': false,
        'isRead': false,
        'isDelivered': true,
        'handle': {'id': '+15551234567', 'service': 'iMessage'},
        'cacheHasAttachments': false,
        'semanticKind': 'normal_text',
        'renderRecommendation': 'bubble',
        'attachments': [],
      });
      expect(m.guid, 'p:0/ABC');
      expect(m.text, 'Hello');
      expect(m.isFromMe, isFalse);
      expect(m.isDelivered, isTrue);
      expect(m.handleId, '+15551234567');
      expect(m.hasText, isTrue);
      expect(m.hasAttachments, isFalse);
      expect(m.localState, LocalSendState.confirmed);
      expect(m.dedupeKey, 'p:0/ABC');
      expect(m.semanticKind, 'normal_text');
      expect(m.renderRecommendation, 'bubble');
    });

    test('parses attachments with kinds', () {
      final m = MessageModel.fromJson({
        'guid': 'g',
        'attachments': [
          {
            'guid': 'a1',
            'mimeType': 'image/jpeg',
            'attachmentKind': 'image',
            'downloadUrl': '/api/attachments/a1',
            'totalBytes': 100,
          },
          {
            'guid': 'a2',
            'uti': 'com.apple.coreaudio-format',
            'attachmentKind': 'audio',
            'isVoiceMessage': true,
            'downloadUrl': '/api/attachments/a2',
          },
        ],
      });
      expect(m.attachments.length, 2);
      expect(m.attachments[0].isImage, isTrue);
      expect(m.attachments[1].isAudio, isTrue);
      expect(m.attachments[1].isVoiceMessage, isTrue);
      expect(m.hasAttachments, isTrue);
    });

    test('filters opaque URL preview payload attachments', () {
      final m = MessageModel.fromJson({
        'guid': 'g',
        'text': 'https://privygallery.cinmou.uk',
        'cacheHasAttachments': true,
        'attachments': [
          {
            'guid': 'noise-1',
            'filename': '88A910B7-31DB-48EF-8124-136AC0D0B9EF',
            'transferName': '88A910B7-31DB-48EF-8124-136AC0D0B9EF',
            'uti': 'public.data',
            'attachmentKind': 'file',
            'displayKind': 'file',
            'downloadUrl': '/api/attachments/noise-1',
            'totalBytes': 121000,
          },
          {
            'guid': 'pdf',
            'transferName': 'report.pdf',
            'attachmentKind': 'file',
            'displayKind': 'file',
            'downloadUrl': '/api/attachments/pdf',
          },
        ],
      });
      expect(m.attachments, hasLength(1));
      expect(m.attachments.single.guid, 'pdf');
    });

    test('optimistic message is sending and keyed by tempId', () {
      final m = MessageModel.optimistic(
        tempId: 'tmp-1',
        text: 'hi',
        dateCreated: 1,
      );
      expect(m.isFromMe, isTrue);
      expect(m.localState, LocalSendState.sending);
      expect(m.guid, '');
      expect(m.dedupeKey, 'tmp-1');
    });

    test('copyWith confirms a pending message and re-keys by guid', () {
      final confirmed = MessageModel.optimistic(
        tempId: 'tmp-1',
        text: 'hi',
        dateCreated: 1,
      ).copyWith(guid: 'real-guid', localState: LocalSendState.confirmed);
      expect(confirmed.guid, 'real-guid');
      expect(confirmed.localState, LocalSendState.confirmed);
      expect(confirmed.dedupeKey, 'real-guid');
    });
  });

  group('AttachmentModel', () {
    test('infers image from mime when kind is unknown', () {
      final a = AttachmentModel.fromJson({
        'guid': 'a',
        'mimeType': 'image/png',
        'downloadUrl': '/x',
      });
      expect(a.isImage, isTrue);
      expect(a.isAudio, isFalse);
    });

    test(
      'infers previewable image from filename when server marks it as file',
      () {
        final a = AttachmentModel.fromJson({
          'guid': 'a',
          'transferName': 'IMG_0001.JPG',
          'attachmentKind': 'file',
          'displayKind': 'file',
          'downloadUrl': '/x',
        });
        expect(a.isImage, isTrue);
        expect(a.canRenderInlineImage, isTrue);
        expect(a.isOpaquePreviewPayload, isFalse);
      },
    );

    test('infers previewable image from Apple image UTI', () {
      final a = AttachmentModel.fromJson({
        'guid': 'a',
        'filename': '/var/mobile/Attachments/photo',
        'uti': 'public.jpeg',
        'attachmentKind': 'file',
        'displayKind': 'file',
        'downloadUrl': '/x',
      });
      expect(a.isImage, isTrue);
      expect(a.canRenderInlineImage, isTrue);
      expect(a.isOpaquePreviewPayload, isFalse);
    });

    test('displayName falls back to a generic label', () {
      final a = AttachmentModel.fromJson({'guid': 'a', 'downloadUrl': '/x'});
      expect(a.displayName, 'Attachment');
    });

    test('detects opaque preview payload rows', () {
      final a = AttachmentModel.fromJson({
        'guid': 'a',
        'filename': 'BD39B7FF-2910-4992-8CD3-7A084A942CF2',
        'transferName': 'BD39B7FF-2910-4992-8CD3-7A084A942CF2',
        'uti': 'public.data',
        'attachmentKind': 'file',
        'displayKind': 'file',
        'downloadUrl': '/x',
      });
      expect(a.isOpaquePreviewPayload, isTrue);
    });

    test('prefers transferName for displayName', () {
      final a = AttachmentModel.fromJson({
        'guid': 'a',
        'transferName': 'photo.heic',
        'filename': '/var/x.heic',
        'downloadUrl': '/x',
      });
      expect(a.displayName, 'photo.heic');
    });

    test('TIFF is image but not inline-previewable', () {
      final a = AttachmentModel.fromJson({
        'guid': 'a',
        'mimeType': 'image/tiff',
        'originalMimeType': 'image/tiff',
        'uti': 'public.tiff',
        'transferName': 'screenshot.tiff',
        'attachmentKind': 'image',
        'displayKind': 'image_needs_preview',
        'isPreviewableImage': false,
        'needsPreviewConversion': true,
        'downloadUrl': '/x',
      });
      expect(a.isImage, isTrue);
      expect(a.isTiff, isTrue);
      expect(a.canRenderInlineImage, isFalse);
      expect(a.displayKind, 'image_needs_preview');
    });

    test(
      'MOV poster preview remains a video with incomplete legacy metadata',
      () {
        final a = AttachmentModel.fromJson({
          'guid': 'mov',
          'transferName': 'IMG_0042.MOV',
          'mimeType': 'image/jpeg',
          'originalMimeType': 'video/quicktime',
          'attachmentKind': 'image',
          'previewUrl': '/api/attachments/mov/preview',
          'downloadUrl': '/api/attachments/mov',
        });

        expect(a.isVideo, isTrue);
        expect(a.isImage, isFalse);
        expect(a.canRenderInlineImage, isFalse);
      },
    );

    test('QuickTime UTI identifies extensionless legacy videos', () {
      final a = AttachmentModel.fromJson({
        'guid': 'mov',
        'filename': '/Library/Messages/Attachments/legacy-file',
        'uti': 'com.apple.quicktime-movie',
        'previewUrl': '/api/attachments/mov/preview',
        'downloadUrl': '/api/attachments/mov',
      });

      expect(a.isVideo, isTrue);
      expect(a.canRenderInlineImage, isFalse);
    });
  });
}
