import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:mica_go/app/theme.dart';
import 'package:mica_go/core/app_controller.dart';
import 'package:mica_go/core/storage/local_cache_store.dart';
import 'package:mica_go/core/storage/secure_store.dart';
import 'package:mica_go/core/theme_controller.dart';
import 'package:mica_go/features/chats/message_thread_screen.dart';
import 'package:mica_go/features/chats/attachment_panel.dart';
import 'package:mica_go/features/chats/models/chat_summary.dart';
import 'package:mica_go/features/chats/models/merged_chat.dart';
import 'package:mica_go/features/chats/models/message_model.dart';
import 'package:mica_go/features/contacts/contacts_service.dart';
import 'package:mica_go/features/settings/message_display_controller.dart';

class _Store implements SecureStore {
  @override
  Future<String?> readValue(String key) async => null;
  @override
  Future<void> writeValue(String key, String value) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Cache extends LocalCacheStore {
  @override
  Future<List<ChatSummary>> listChats({
    bool includeDebug = false,
    bool includeHidden = false,
  }) async => [];
  @override
  Future<List<MessageModel>> listMessages(
    String chatGuid, {
    int? limit = 200,
  }) async => [
    for (final emoji in ['😐', '🙂', '🙃', '🙁'])
      MessageModel(
        guid: emoji,
        chatGuid: chatGuid,
        text: emoji,
        dateCreated: 1700000000000,
      ),
  ];
}

class _App extends AppController {
  _App() : super(store: _Store());
  final fixture = _Cache();
  @override
  LocalCacheStore get cache => fixture;
  @override
  Future<void> markChatsViewed(Iterable<String> guids, {int? upTo}) async {}
}

void main() {
  testWidgets('Linux composer stages menu, pasted and dropped attachments', (
    tester,
  ) async {
    const recorder = MethodChannel('com.llfbandit.record/messages');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      recorder,
      (_) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        recorder,
        null,
      ),
    );
    final app = _App();
    final theme = ThemeController(store: app.store);
    await theme.setColorChoice(ThemeColorChoice.linuxDesktop);
    final contacts = ContactsService(store: app.store);
    final display = MessageDisplayController(store: app.store);
    addTearDown(app.dispose);
    addTearDown(theme.dispose);
    addTearDown(contacts.dispose);
    addTearDown(display.dispose);
    const desktop = MethodChannel('micago/linux_desktop');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(desktop, (
      call,
    ) async {
      calls.add(call);
      return <String>[];
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        desktop,
        null,
      ),
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppController>.value(value: app),
          ChangeNotifierProvider<ThemeController>.value(value: theme),
          ChangeNotifierProvider<ContactsService>.value(value: contacts),
          ChangeNotifierProvider<MessageDisplayController>.value(
            value: display,
          ),
        ],
        child: MaterialApp(
          theme: MicaGoTheme.linux(Brightness.dark),
          home: const Scaffold(
            body: MessageThreadScreen(
              embedded: true,
              merged: MergedChat(
                key: 'chat',
                routes: [
                  ChatSummary(
                    guid: 'chat',
                    effectiveService: 'imessage',
                    canSendTextRaw: true,
                    canSendAttachmentsRaw: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
      expect(
        MicaGoTheme.linux(Brightness.dark).textTheme.bodyMedium!.fontFamily,
        'sans-serif',
      );
    for (final emoji in ['😐', '🙂', '🙃', '🙁']) {
      final text = tester.widget<Text>(find.text(emoji));
        expect(text.style!.fontFamily, 'sans-serif');
      expect(text.style!.fontFamilyFallback!.first, 'Noto Color Emoji');
    }
    expect(find.byIcon(Icons.mic_none), findsNothing);
    expect(find.byIcon(Icons.emoji_emotions_outlined), findsOneWidget);
    final plus = find
        .ancestor(of: find.byIcon(Icons.add), matching: find.byType(IconButton))
        .first;
    expect(
      tester.widget<IconButton>(plus).color,
      MicaGoTheme.linux(Brightness.dark).colorScheme.onSurface,
    );
    await tester.tap(plus);
    await tester.pumpAndSettle();
    expect(find.text('Choose files…'), findsOneWidget);
    expect(find.text('Record audio'), findsOneWidget);
    expect(
      find.byWidgetPredicate((widget) => widget is PopupMenuItem),
      findsNWidgets(2),
    );
    await tester.tap(find.text('Choose files…'));
    await tester.pumpAndSettle();
    expect(calls.single.method, 'pickFiles');

    final directory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('micago-paste-test-'),
    );
    addTearDown(() => directory!.delete(recursive: true));
    final document = File('${directory!.path}/文件 with spaces.pdf');
    final image = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKElEQVR4nO3NMQEAAAjDMMC/ZzDBvlRA01vZJvwHAAAAAAAAAAAAbx2jxAE/i2AjOgAAAABJRU5ErkJggg==',
    );
    await tester.runAsync(() => document.writeAsString('test document'));
    var clipboardFiles = <String>[document.path];
    final clipboardImage = image;
    const pasteboard = MethodChannel('pasteboard');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pasteboard,
      (call) async => switch (call.method) {
        'files' => clipboardFiles,
        'image' => clipboardImage,
        _ => null,
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pasteboard,
        null,
      ),
    );

    Future<void> paste() async {
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      editable.widget.focusNode.requestFocus();
      await tester.pump();
      await tester.runAsync(() async {
        final result = Actions.invoke(
          editable.widget.focusNode.context!,
          const PasteTextIntent(SelectionChangedCause.keyboard),
        );
        if (result is Future) await result;
      });
      await tester.pumpAndSettle();
    }

    // File payload takes priority over the image offered by the same copy.
    await paste();
    var strip = tester.widget<StagedAttachmentStrip>(
      find.byType(StagedAttachmentStrip),
    );
    expect(strip.items.single.filename, '文件 with spaces.pdf');
    expect(strip.items.single.path, document.path);
    expect(strip.items.single.bytes, isNull);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );

    clipboardFiles = [];
    await paste();
    strip = tester.widget<StagedAttachmentStrip>(
      find.byType(StagedAttachmentStrip),
    );
    expect(strip.items, hasLength(2));
    expect(strip.items.last.bytes, image);

    final dropPosition = tester.getCenter(find.byType(DropTarget));
    tester.binding.channelBuffers.push(
      'desktop_drop',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('entered', [dropPosition.dx, dropPosition.dy]),
      ),
      (_) {},
    );
    await tester.pump();
    await tester.runAsync(() async {
      tester.binding.channelBuffers.push(
        'desktop_drop',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('performOperation', [document.path, document.path]),
        ),
        (_) {},
      );
      // Let the asynchronous filesystem stat finish before checking the UI.
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    strip = tester.widget<StagedAttachmentStrip>(
      find.byType(StagedAttachmentStrip),
    );
    expect(strip.items, hasLength(3));
    expect(strip.items.last.path, document.path);

    clipboardFiles = [
      directory.path,
      '${directory.path}/missing.pdf',
      document.uri.toString(),
    ];
    await paste();
    strip = tester.widget<StagedAttachmentStrip>(
      find.byType(StagedAttachmentStrip),
    );
    expect(strip.items, hasLength(4));
    expect(strip.items.last.path, document.path);
    await tester.pump(const Duration(seconds: 5));

    final pendingFiles = Completer<List<String>>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pasteboard,
      (_) => pendingFiles.future,
    );
    final editable = tester.state<EditableTextState>(find.byType(EditableText));
    final pendingPaste = Actions.invoke(
      editable.widget.focusNode.context!,
      const PasteTextIntent(SelectionChangedCause.keyboard),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    pendingFiles.complete([document.path]);
    if (pendingPaste is Future) await pendingPaste;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
