import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mica_go/app/theme.dart';
import 'package:mica_go/core/l10n/app_localizations.dart';
import 'package:mica_go/core/network/api_client.dart';
import 'package:mica_go/core/platform/android_emoji_font.dart';
import 'package:mica_go/core/platform/linux_desktop.dart';
import 'package:mica_go/core/storage/media_cache.dart';
import 'package:mica_go/features/chats/attachment_panel.dart';
import 'package:mica_go/features/chats/attachment_views.dart';
import 'package:mica_go/features/chats/image_input_helpers.dart';
import 'package:mica_go/features/chats/message_thread_screen.dart'
    show withCompatSymbolFallback;
import 'package:mica_go/features/chats/models/message_model.dart';
import 'package:mica_go/features/chats/store/message_collection.dart';

final Uint8List _samplePng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKElEQVR4nO3NMQEAAAjDMMC/ZzDBvlRA01vZJvwHAAAAAAAAAAAAbx2jxAE/i2AjOgAAAABJRU5ErkJggg==',
);

void main() {
  tearDown(() {
    AndroidUpdatedEmojiFont.resetForTest();
  });

  group('AndroidUpdatedEmojiFont', () {
    test('skips loading on non-Android platforms', () async {
      var probed = false;
      final loaded = await AndroidUpdatedEmojiFont.loadIfAvailable(
        isAndroidOverride: false,
        findFontPath: () async {
          probed = true;
          return '/data/fonts/files/NotoColorEmoji.ttf';
        },
      );
      expect(loaded, isNull);
      expect(probed, isFalse);
      expect(AndroidUpdatedEmojiFont.loadedFamily.value, isNull);
    });

    test('loads updated Android emoji font and wires theme fallback', () async {
      String? registeredFamily;
      int? registeredLength;
      final loaded = await AndroidUpdatedEmojiFont.loadIfAvailable(
        isAndroidOverride: true,
        findFontPath: () async => '/data/fonts/files/NotoColorEmoji.ttf',
        readBytes: (_) async => Uint8List.fromList([1, 2, 3, 4]),
        registerFont: (family, bytes) async {
          registeredFamily = family;
          registeredLength = bytes.length;
        },
      );
      expect(loaded, AndroidUpdatedEmojiFont.familyName);
      expect(registeredFamily, AndroidUpdatedEmojiFont.familyName);
      expect(registeredLength, 4);
      expect(
        AndroidUpdatedEmojiFont.loadedFamily.value,
        AndroidUpdatedEmojiFont.familyName,
      );

      final theme = MicaGoTheme.fromScheme(
        ColorScheme.fromSeed(seedColor: Colors.blue),
        extraEmojiFont: loaded,
      );
      expect(
        theme.textTheme.bodyMedium?.fontFamilyFallback,
        containsAllInOrder([
          'MicaGoCompatSymbols',
          AndroidUpdatedEmojiFont.familyName,
        ]),
      );
    });

    test('ignores missing or unreadable updated emoji font safely', () async {
      final loaded = await AndroidUpdatedEmojiFont.loadIfAvailable(
        isAndroidOverride: true,
        findFontPath: () async => '/data/fonts/files/missing.ttf',
        readBytes: (_) async => throw StateError('unreadable'),
      );
      expect(loaded, isNull);
      expect(AndroidUpdatedEmojiFont.loadedFamily.value, isNull);
    });
  });

  group('image input helpers & Linux clipboard', () {
    test('detectImageMimeType identifies common raster formats', () {
      expect(detectImageMimeType(_samplePng), 'image/png');
      expect(
        detectImageMimeType(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])),
        'image/jpeg',
      );
      expect(
        detectImageMimeType(Uint8List.fromList(utf8.encode('GIF89a'))),
        'image/gif',
      );
      expect(
        detectImageMimeType(Uint8List.fromList(utf8.encode('RIFF1234WEBP'))),
        'image/webp',
      );
      expect(
        detectImageMimeType(Uint8List.fromList([0x42, 0x4D, 0x00, 0x00])),
        'image/bmp',
      );
      expect(
        detectImageMimeType(Uint8List.fromList(utf8.encode('plain text'))),
        isNull,
      );
    });

    test('StagedAttachment recognizes extensionless pasted image bytes', () {
      final staged = StagedAttachment(bytes: _samplePng, filename: 'clipboard');
      expect(staged.isImage, isTrue);
    });

    test('probeImageAspectRatio reads PNG header and formats compact bytes', () async {
      final ratio = await probeImageAspectRatio(bytes: _samplePng);
      expect(ratio, closeTo(1.0, 0.01));
      expect(formatCompactBytes(512), '512 B');
      expect(formatCompactBytes(2048), '2 KB');
      expect(formatCompactBytes(3 * 1024 * 1024), '3.0 MB');
    });

    testWidgets('StagedAttachmentStrip shows count and total size summary', (
      tester,
    ) async {
      final items = [
        StagedAttachment(bytes: _samplePng, filename: 'a.png'),
        StagedAttachment(bytes: Uint8List(2048), filename: 'doc.pdf'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StagedAttachmentStrip(items: items, onRemove: (_) {}),
          ),
        ),
      );
      expect(find.text('2'), findsOneWidget);
      expect(find.text('2 KB'), findsOneWidget);
    });

    test('parseLinuxClipboardUriList decodes GNOME and uri-list entries', () {
      final paths = parseLinuxClipboardUriList(
        'copy\r\n# comment\r\nfile:///tmp/my%20photo.png\r\nfile:///tmp/%E5%9B%BE%E7%89%87.jpg\r\n',
      );
      expect(paths, ['/tmp/my photo.png', '/tmp/图片.jpg']);
    });

    testWidgets(
      'LinuxDesktop.readClipboardAttachments decodes native bytes payload',
      (tester) async {
        const channel = MethodChannel('micago/linux_desktop');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            if (call.method == 'readClipboardAttachments') {
              return {'bytes': _samplePng, 'mimeType': 'image/png'};
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );

        final payload = await LinuxDesktop.readClipboardAttachments();
        expect(payload, isNotNull);
        expect(payload!.paths, isEmpty);
        expect(payload.imageBytes, _samplePng);
        expect(payload.mimeType, 'image/png');
      },
    );
  });

  group('image display optimizations', () {
    test('computeChatImageSize balances portrait, square, and wide photos', () {
      // Portrait 1:2 stays 153x306.
      final portrait = computeChatImageSize(
        rawAspect: 0.5,
        availableWidth: 600,
      );
      expect(portrait.width, closeTo(153, 0.1));
      expect(portrait.height, closeTo(306, 0.1));

      // Square 1:1 shrinks to 228x228 instead of an oversized 306x306 block.
      final square = computeChatImageSize(rawAspect: 1.0, availableWidth: 600);
      expect(square.width, closeTo(228, 0.1));
      expect(square.height, closeTo(228, 0.1));

      // Desktop wide 16:9 caps width at 276 instead of sprawling to 544px.
      final wide = computeChatImageSize(
        rawAspect: 16 / 9,
        availableWidth: 900,
      );
      expect(wide.width, closeTo(276, 0.1));
      expect(wide.height, closeTo(276 / (16 / 9), 0.1));
    });

    testWidgets('clamps ultra-tall image ratio and shows long-image badge', (
      tester,
    ) async {
      final api = ApiClient(
        baseUrl: 'http://localhost',
        token: 'test',
        httpClient: MockClient(
          (_) async => http.Response.bytes(_samplePng, 200),
        ),
      );
      MediaCache.instance.rememberAspectRatio('thumb:v1:long-img', 0.2);
      MediaCache.instance.pinLocal('local-long', _samplePng);
      MediaCache.instance.rememberAspectRatio('local-long', 0.2);
      addTearDown(() => MediaCache.instance.unpinLocal('local-long'));

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [MicaLocalizations.delegate],
          home: Scaffold(
            body: Center(
              child: AttachmentView(
                api: api,
                attachment: const AttachmentModel(
                  guid: 'local-long',
                  downloadUrl: '/api/attachments/local-long',
                  filename: 'tall.png',
                  mimeType: 'image/png',
                  attachmentKind: 'image',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final size = tester.getSize(find.byType(AttachmentView));
      // Aspect 0.2 clamps to 0.45 -> width ~137.7 instead of collapsing to 61.2.
      expect(size.width, closeTo(306 * 0.45, 0.5));
      expect(size.height, closeTo(306, 0.5));
      expect(find.text('Long'), findsOneWidget);
    });

    testWidgets('MediaAlbumGrid renders 10 images with +1 overflow badge', (
      tester,
    ) async {
      final api = ApiClient(
        baseUrl: 'http://localhost',
        token: 'test',
        httpClient: MockClient(
          (_) async => http.Response.bytes(_samplePng, 200),
        ),
      );
      final images = List.generate(
        10,
        (i) => AttachmentModel(
          guid: 'local-album-$i',
          downloadUrl: '/api/attachments/local-album-$i',
          filename: 'photo_$i.png',
          mimeType: 'image/png',
          attachmentKind: 'image',
        ),
      );
      for (final img in images) {
        MediaCache.instance.pinLocal(img.guid, _samplePng);
      }
      addTearDown(() {
        for (final img in images) {
          MediaCache.instance.unpinLocal(img.guid);
        }
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MediaAlbumGrid(
                api: api,
                images: images,
                galleryImages: images,
                galleryIndexFor: (a) => images.indexOf(a),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('+1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('big-emoji text style preserves Android updated 3D emoji fallback', () {
      AndroidUpdatedEmojiFont.loadedFamily.value =
          AndroidUpdatedEmojiFont.familyName;
      final style = withCompatSymbolFallback(
        const TextStyle(fontSize: 86.4, height: 1.1),
        inheritedFallback: const [
          'MicaGoCompatSymbols',
          AndroidUpdatedEmojiFont.familyName,
        ],
      );
      expect(
        style.fontFamilyFallback,
        contains(AndroidUpdatedEmojiFont.familyName),
      );
      expect(style.fontSize, 86.4);
    });

    test('retracted messages strip stale attachments in fromJson and copyWith', () {
      final fromJson = MessageModel.fromJson({
        'guid': 'm-retracted',
        'isFromMe': true,
        'isRetracted': true,
        'dateRetracted': 1700000000000,
        'cacheHasAttachments': true,
        'attachments': [
          {
            'guid': 'att-retracted',
            'downloadUrl': '/api/attachments/att-retracted',
            'filename': 'photo.jpg',
            'mimeType': 'image/jpeg',
            'attachmentKind': 'image',
          },
        ],
      });
      expect(fromJson.isRetracted, isTrue);
      expect(fromJson.attachments, isEmpty);
      expect(fromJson.cacheHasAttachments, isFalse);

      final normal = MessageModel(
        guid: 'm-live',
        isFromMe: true,
        cacheHasAttachments: true,
        attachments: const [
          AttachmentModel(
            guid: 'att-live',
            downloadUrl: '/api/attachments/att-live',
            filename: 'photo.jpg',
            mimeType: 'image/jpeg',
            attachmentKind: 'image',
          ),
        ],
      );
      final retracted = normal.copyWith(
        isRetracted: true,
        dateRetracted: 1700000000000,
      );
      expect(retracted.isRetracted, isTrue);
      expect(retracted.attachments, isEmpty);
      expect(retracted.cacheHasAttachments, isFalse);
    });

    test('emoji reconciliation ignores variation selector differences', () {
      final local = MessageModel.optimistic(
        tempId: 'tmp-emoji-1',
        text: '❤️',
        dateCreated: 1700000000000,
      ).copyWith(chatGuid: 'iMessage;-;test@example.com');
      final server = MessageModel(
        guid: 'srv-emoji-1',
        chatGuid: 'iMessage;-;test@example.com',
        isFromMe: true,
        text: '\u2764',
        dateCreated: 1700000001000,
      );
      expect(shouldReconcileLocalWithServer(local, server), isTrue);
    });
  });
}
