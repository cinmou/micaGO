import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mica_go/core/network/api_client.dart';
import 'package:mica_go/features/chats/attachment_views.dart';
import 'package:mica_go/features/chats/message_thread_screen.dart';
import 'package:mica_go/features/chats/models/message_model.dart';

AttachmentModel _att({
  required String guid,
  required String kind,
  String? mime,
  String? name,
}) => AttachmentModel(
  guid: guid,
  downloadUrl: '/api/attachments/$guid',
  filename: name,
  mimeType: mime,
  attachmentKind: kind,
);

void main() {
  final api = ApiClient(baseUrl: 'http://localhost:0', token: 't');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('EmojiPanel renders and tapping inserts the tapped emoji', (
    tester,
  ) async {
    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: EmojiPanel(onPick: (e) => picked = e)),
      ),
    );
    // The first Smileys emoji is rendered; tap it.
    expect(find.text('😀'), findsOneWidget);
    await tester.tap(find.text('😀'));
    expect(picked, '😀');

    // Switching category shows a different set (hearts contains a heart).
    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pumpAndSettle();
    expect(find.text('❤️'), findsOneWidget);
  });

  testWidgets('EmojiPanel.remember builds a Recent category', (tester) async {
    EmojiPanel.remember('🔥');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: EmojiPanel(onPick: (_) {})),
      ),
    );
    // A history (Recent) tab appears once something has been remembered.
    expect(find.byIcon(Icons.history), findsOneWidget);
    await tester.tap(find.byIcon(Icons.history));
    await tester.pumpAndSettle();
    expect(find.text('🔥'), findsWidgets);
  });

  testWidgets('a video attachment renders a tappable preview (no crash)', (
    tester,
  ) async {
    // Serve a valid preview thumbnail so the video renders its preview path
    // deterministically (no real network, no pending request timer).
    final videoApi = ApiClient(
      baseUrl: 'http://localhost:0',
      token: 't',
      httpClient: MockClient((_) async => http.Response.bytes(_png1x1, 200)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AttachmentView(
            api: videoApi,
            attachment: _att(
              guid: 'v1',
              kind: 'video',
              mime: 'video/mp4',
              name: 'clip.mp4',
            ),
          ),
        ),
      ),
    );
    await tester.pump(); // resolve the preview future
    // Preview thumbnail shows a play affordance and is tappable; never throws.
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.byType(GestureDetector), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('loading media never renders a second progress bubble', (
    tester,
  ) async {
    final release = Completer<void>();
    final loadingApi = ApiClient(
      baseUrl: 'http://localhost:0',
      token: 't',
      httpClient: MockClient((_) async {
        await release.future;
        return http.Response.bytes(_png1x1, 200);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              AttachmentView(
                api: loadingApi,
                attachment: _att(
                  guid: 'image-loading',
                  kind: 'image',
                  mime: 'image/png',
                  name: 'photo.png',
                ),
              ),
              AttachmentView(
                api: loadingApi,
                attachment: _att(
                  guid: 'video-loading',
                  kind: 'video',
                  mime: 'video/mp4',
                  name: 'clip.mp4',
                ),
              ),
              AttachmentView(
                api: loadingApi,
                attachment: const AttachmentModel(
                  guid: 'sticker-loading',
                  downloadUrl: '/api/attachments/sticker-loading',
                  filename: 'sticker.png',
                  isSticker: true,
                  attachmentKind: 'sticker',
                  displayKind: 'sticker',
                  isPreviewableImage: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsNothing);
    // C69: while bytes load, each media kind shows its in-bubble skeleton
    // placeholder (image / video / sticker) — never a spinner bubble and
    // never a bare file card that swaps shape when the media arrives.
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
    expect(find.byIcon(Icons.auto_awesome_outlined), findsOneWidget);

    release.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    // Loaded media fades over the still-present placeholder while the same
    // frame eases to its final size. No bubble entrance/scale animation runs.
    expect(find.byType(Image), findsWidgets);
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
    expect(find.byIcon(Icons.auto_awesome_outlined), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.image_outlined), findsNothing);
    expect(find.byIcon(Icons.videocam_outlined), findsNothing);
    expect(find.byIcon(Icons.auto_awesome_outlined), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unsupported file renders a file card and does not crash', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AttachmentView(
            api: api,
            attachment: _att(
              guid: 'f1',
              kind: 'file',
              mime: 'application/octet-stream',
              name: 'data.bin',
            ),
          ),
        ),
      ),
    );
    expect(find.text('data.bin'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a sticker attachment renders as visual media, not a file card', (
    tester,
  ) async {
    final stickerApi = ApiClient(
      baseUrl: 'http://localhost:0',
      token: 't',
      httpClient: MockClient((_) async => http.Response.bytes(_png1x1, 200)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AttachmentView(
            api: stickerApi,
            attachment: const AttachmentModel(
              guid: 's1',
              downloadUrl: '/api/attachments/s1',
              filename: 'sticker.heic',
              isSticker: true,
              attachmentKind: 'sticker',
              displayKind: 'sticker',
              isPreviewableImage: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.emoji_emotions_outlined), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a sticker falls back to raw bytes when preview conversion fails',
    (tester) async {
      final seen = <String>[];
      final stickerApi = ApiClient(
        baseUrl: 'http://localhost:0',
        token: 't',
        httpClient: MockClient((request) async {
          seen.add(request.url.path);
          if (request.url.path.endsWith('/preview')) {
            return http.Response('preview unavailable', 501);
          }
          return http.Response.bytes(_png1x1, 200);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AttachmentView(
              api: stickerApi,
              attachment: const AttachmentModel(
                guid: 's-preview',
                downloadUrl: '/api/attachments/s-preview',
                previewUrl: '/api/attachments/s-preview/preview',
                filename: 'sticker.heic',
                isSticker: true,
                attachmentKind: 'sticker',
                displayKind: 'sticker',
                needsPreviewConversion: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(seen, [
        '/api/attachments/s-preview/preview',
        '/api/attachments/s-preview',
      ]);
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('Sticker'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an un-renderable sticker shows a clean Sticker placeholder, not a file card',
    (tester) async {
      // A third-party sticker whose bytes can't be fetched/decoded.
      final stickerApi = ApiClient(
        baseUrl: 'http://localhost:0',
        token: 't',
        httpClient: MockClient((_) async => http.Response('nope', 500)),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AttachmentView(
              api: stickerApi,
              attachment: const AttachmentModel(
                guid: 's2',
                downloadUrl: '/api/attachments/s2',
                filename: 'pack.heic',
                isSticker: true,
                attachmentKind: 'sticker',
                displayKind: 'sticker',
                needsPreviewConversion: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Clean "Sticker" placeholder — never a broken/empty file card.
      expect(find.text('Sticker'), findsOneWidget);
      expect(find.text('pack.heic'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a location attachment renders a Location card with Open in Maps', (
    tester,
  ) async {
    final locApi = ApiClient(
      baseUrl: 'http://localhost:0',
      token: 't',
      httpClient: MockClient(
        (_) async => http.Response(
          'BEGIN:VCARD\nURL:https://maps.apple.com/?ll=37.33,-122.03\nEND:VCARD',
          200,
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AttachmentView(
            api: locApi,
            attachment: const AttachmentModel(
              guid: 'loc1',
              downloadUrl: '/api/attachments/loc1',
              transferName: 'CL.loc.vcf',
              mimeType: 'text/x-vlocation',
              attachmentKind: 'location',
              displayKind: 'location',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Location'), findsWidgets);
    expect(find.text('Open in Maps'), findsOneWidget);
    expect(find.byIcon(Icons.location_on), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long-press opens normal message action menu', (tester) async {
    const msg = MessageModel(guid: 'm1', text: 'Copy me');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => GestureDetector(
              onLongPressStart: (details) =>
                  showMessageActionMenu(context, msg, details.globalPosition),
              child: const Text('Copy me'),
            ),
          ),
        ),
      ),
    );

    await tester.longPress(find.text('Copy me'));
    await tester.pumpAndSettle();

    expect(find.text('Copy'), findsOneWidget);
    // C39: the long-press "Message Info" entry was removed.
    expect(find.text('Message Info'), findsNothing);
    expect(find.text('Copy debug JSON'), findsNothing);
  });

  testWidgets('copy action copies text messages', (tester) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            final args = call.arguments as Map<dynamic, dynamic>;
            copied = args['text'] as String?;
          }
          return null;
        });
    const msg = MessageModel(guid: 'm1', text: 'Copy me');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => GestureDetector(
              onLongPressStart: (details) =>
                  showMessageActionMenu(context, msg, details.globalPosition),
              child: const Text('Copy me'),
            ),
          ),
        ),
      ),
    );

    await tester.longPress(find.text('Copy me'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();

    expect(copied, 'Copy me');
    expect(find.text('Message copied'), findsOneWidget);
  });

  testWidgets('supported backend actions appear in the long-press menu', (
    tester,
  ) async {
    final actionApi = ApiClient(
      baseUrl: 'http://localhost:0',
      token: 't',
      httpClient: MockClient((request) async {
        if (request.url.path == '/api/messages/actions/capabilities') {
          return http.Response(
            '{"available":true,"edit":true,"retract":true,"delete":true}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 404);
      }),
    );
    const msg = MessageModel(guid: 'm1', text: 'Mutable', isFromMe: true);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => GestureDetector(
              onLongPressStart: (details) => showMessageActionMenu(
                context,
                msg,
                details.globalPosition,
                chatGuid: 'chat-1',
                api: actionApi,
              ),
              child: const Text('Mutable'),
            ),
          ),
        ),
      ),
    );

    await tester.longPress(find.text('Mutable'));
    await tester.pumpAndSettle();

    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Message Info'), findsNothing);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Undo Send'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
  });
}

const _png1x1 = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];
