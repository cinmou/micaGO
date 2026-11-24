import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:provider/provider.dart';

import 'package:mica_go/app/theme.dart';
import 'package:mica_go/core/app_controller.dart';
import 'package:mica_go/core/l10n/app_localizations.dart';
import 'package:mica_go/core/storage/local_cache_store.dart';
import 'package:mica_go/core/storage/secure_store.dart';
import 'package:mica_go/core/theme_controller.dart';
import 'package:mica_go/core/ui/glass_theme_widgets.dart';
import 'package:mica_go/features/chats/chats_pane.dart';
import 'package:mica_go/features/chats/message_thread_screen.dart';
import 'package:mica_go/features/chats/models/chat_summary.dart';
import 'package:mica_go/features/chats/models/merged_chat.dart';
import 'package:mica_go/features/chats/models/message_model.dart';
import 'package:mica_go/features/contacts/contacts_service.dart';
import 'package:mica_go/features/settings/message_display_controller.dart';
import 'package:mica_go/features/settings/settings_screen.dart';

class _TestStore implements SecureStore {
  final values = <String, String>{};

  @override
  Future<bool> compatibilityStorageEnabled() async => false;

  @override
  Future<String?> readValue(String key) async => values[key];

  @override
  Future<void> writeValue(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> deleteValue(String key) async {
    values.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestCache extends LocalCacheStore {
  final List<MessageModel> threadMessages;
  _TestCache({this.threadMessages = const []});

  @override
  Future<String?> readMetadata(String key) async => null;

  @override
  Future<void> writeMetadata(String key, String value) async {}

  @override
  Future<List<ChatSummary>> listChats({
    bool includeDebug = false,
    bool includeHidden = false,
  }) async => [];

  @override
  Future<List<MessageModel>> listMessages(
    String chatGuid, {
    int? limit = 200,
  }) async => threadMessages;
}

class _TestApp extends AppController {
  final _TestCache _cache;
  _TestApp({List<MessageModel> messages = const []})
    : _cache = _TestCache(threadMessages: messages),
      super(store: _TestStore());

  @override
  LocalCacheStore get cache => _cache;

  @override
  Future<void> markChatsViewed(Iterable<String> guids, {int? upTo}) async {}
}

Widget _wrapProviders({
  required AppController app,
  required ThemeController theme,
  required ContactsService contacts,
  required MessageDisplayController display,
  required Widget home,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppController>.value(value: app),
      ChangeNotifierProvider<ThemeController>.value(value: theme),
      ChangeNotifierProvider<ContactsService>.value(value: contacts),
      ChangeNotifierProvider<MessageDisplayController>.value(value: display),
    ],
    child: Consumer<ThemeController>(
      builder: (context, activeTheme, _) {
        final baseLight = activeTheme.useBlackWhite
            ? MicaGoTheme.blackWhiteScheme(Brightness.light)
            : ColorScheme.fromSeed(seedColor: activeTheme.seedColor);
        final scheme = activeTheme.useLiquidGlass
            ? MicaGoTheme.liquidGlassScheme(
                Brightness.light,
                base: baseLight,
                isBrandDefault:
                    !activeTheme.useBlackWhite &&
                    activeTheme.colorChoice == ThemeColorChoice.micago,
              )
            : baseLight;
        return MaterialApp(
          locale: const Locale('en'),
          supportedLocales: const [Locale('en')],
          localizationsDelegates: const [MicaLocalizations.delegate],
          theme: MicaGoTheme.fromScheme(scheme),
          home: home,
        );
      },
    ),
  );
}

void main() {
  testWidgets(
    'appearance settings decouples liquid glass switch and color choices',
    (tester) async {
      final app = _TestApp();
      final theme = ThemeController(store: app.store);
      final contacts = ContactsService(store: app.store);
      final display = MessageDisplayController(store: app.store);
      addTearDown(app.dispose);
      addTearDown(theme.dispose);
      addTearDown(contacts.dispose);
      addTearDown(display.dispose);

      await tester.pumpWidget(
        _wrapProviders(
          app: app,
          theme: theme,
          contacts: contacts,
          display: display,
          home: const SettingsScreen(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Appearance'));
      await tester.pumpAndSettle();

      final toggle = find.widgetWithText(SwitchListTile, 'Liquid glass');
      expect(toggle, findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Glass'), findsNothing);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(theme.useLiquidGlass, isTrue);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Bicao'));
      await tester.pumpAndSettle();
      expect(theme.useLiquidGlass, isTrue);
      expect(theme.colorChoice, ThemeColorChoice.bicao);

      final ctx = tester.element(find.widgetWithText(ChoiceChip, 'Bicao'));
      final expectedBicao = ColorScheme.fromSeed(
        seedColor: const Color(0xFF2E7D32),
      ).primary;
      expect(Theme.of(ctx).colorScheme.primary, expectedBicao);
    },
  );

  testWidgets(
    'wide ChatsPane sidebar header matches liquid glass header color',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final app = _TestApp();
      final theme = ThemeController(store: app.store);
      await theme.setLiquidGlassEnabled(true);
      await theme.setColorChoice(ThemeColorChoice.bicao);
      final contacts = ContactsService(store: app.store);
      final display = MessageDisplayController(store: app.store);
      addTearDown(app.dispose);
      addTearDown(theme.dispose);
      addTearDown(contacts.dispose);
      addTearDown(display.dispose);

      await tester.pumpWidget(
        _wrapProviders(
          app: app,
          theme: theme,
          contacts: contacts,
          display: display,
          home: const Scaffold(body: ChatsPane()),
        ),
      );
      await tester.pumpAndSettle();

      final titleFinder = find.text('micaGO');
      expect(titleFinder, findsOneWidget);
      final titleContext = tester.element(titleFinder);
      final expectedHeader = liquidGlassHeaderColor(titleContext);

      final headerBox = tester.widget<DecoratedBox>(
        find.ancestor(of: titleFinder, matching: find.byType(DecoratedBox)).first,
      );
      expect((headerBox.decoration as BoxDecoration).color, expectedHeader);
    },
  );

  testWidgets(
    'liquid glass message bubbles use CustomPaint without per-bubble GlassContainer and follow theme color',
    (tester) async {
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

      final app = _TestApp(
        messages: const [
          MessageModel(
            guid: 'm-out',
            chatGuid: 'chat-1',
            text: 'Outgoing glass bubble',
            isFromMe: true,
            dateCreated: 1700000001000,
          ),
          MessageModel(
            guid: 'm-in',
            chatGuid: 'chat-1',
            text: 'Incoming glass bubble',
            isFromMe: false,
            dateCreated: 1700000000000,
          ),
        ],
      );
      final theme = ThemeController(store: app.store);
      await theme.setLiquidGlassEnabled(true);
      await theme.setColorChoice(ThemeColorChoice.bicao);
      final contacts = ContactsService(store: app.store);
      final display = MessageDisplayController(store: app.store);
      addTearDown(app.dispose);
      addTearDown(theme.dispose);
      addTearDown(contacts.dispose);
      addTearDown(display.dispose);

      await tester.pumpWidget(
        _wrapProviders(
          app: app,
          theme: theme,
          contacts: contacts,
          display: display,
          home: const Scaffold(
            body: MessageThreadScreen(
              embedded: true,
              merged: MergedChat(
                key: 'chat-1',
                routes: [
                  ChatSummary(
                    guid: 'chat-1',
                    effectiveService: 'imessage',
                    canSendTextRaw: true,
                    canSendAttachmentsRaw: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final outgoingText = find.text('Outgoing glass bubble');
      final incomingText = find.text('Incoming glass bubble');
      expect(outgoingText, findsOneWidget);
      expect(incomingText, findsOneWidget);

      // No per-bubble GlassContainer in the thread list.
      expect(find.byType(GlassContainer), findsNothing);
      expect(
        find.ancestor(of: outgoingText, matching: find.byType(CustomPaint)),
        findsWidgets,
      );

      final outgoingCtx = tester.element(outgoingText);
      final expectedPrimary = ColorScheme.fromSeed(
        seedColor: const Color(0xFF2E7D32),
      ).primary;
      expect(Theme.of(outgoingCtx).colorScheme.primary, expectedPrimary);
      expect(tester.takeException(), isNull);
    },
  );
}
