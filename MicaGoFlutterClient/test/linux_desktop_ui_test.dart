import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:mica_go/core/app_controller.dart';
import 'package:mica_go/core/storage/secure_store.dart';
import 'package:mica_go/core/theme_controller.dart';
import 'package:mica_go/features/contacts/contacts_service.dart';
import 'package:mica_go/features/settings/message_display_controller.dart';
import 'package:mica_go/features/settings/settings_screen.dart';
import 'package:mica_go/core/ui/app_dialog.dart';
import 'package:mica_go/core/ui/linux_context_actions.dart';
import 'package:mica_go/core/ui/top_banner.dart';
import 'package:mica_go/features/settings/contacts_matching_tile.dart';

class _SettingsStore implements SecureStore {
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImportContacts extends ContactsService {
  _ImportContacts() : super(store: _SettingsStore());

  final completed = Completer<void>.sync();
  final imported = <String>[];

  @override
  Future<({int imported, int skipped, int photoErrors})> importLinuxVCardFile(
    String path,
  ) async {
    imported.add(await File(path).readAsString());
    completed.complete();
    return (imported: 1, skipped: 0, photoErrors: 0);
  }
}

void main() {
  testWidgets(
    'background parsing reports invalid exports after a failed import',
    (tester) async {
      await tester.runAsync(() async {
        final contacts = ContactsService(store: _SettingsStore());
        final directory = await Directory.systemTemp.createTemp(
          'micago-invalid-',
        );
        try {
          final file = await File(
            '${directory.path}/invalid.vcf',
          ).writeAsString('not a vCard');
          await expectLater(
            contacts.importLinuxVCardFile(file.path),
            throwsFormatException,
          );
          await expectLater(
            contacts.importLinuxVCard('not a vCard'),
            throwsFormatException,
          );
        } finally {
          contacts.dispose();
          await directory.delete(recursive: true);
        }
      });
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('contact import reads the native selection and handles cancel', (
    tester,
  ) async {
    final directory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('micago-import-ui-'),
    );
    addTearDown(() => directory!.delete(recursive: true));
    const vcard =
        'BEGIN:VCARD\nVERSION:3.0\nFN:Test\nTEL:+19995550123\nEND:VCARD\n';
    final file = File('${directory!.path}/测试 contact.VCF');
    await tester.runAsync(() => file.writeAsString(vcard));
    final contacts = _ImportContacts();
    addTearDown(contacts.dispose);
    const channel = MethodChannel('micago/linux_desktop');
    String? selection = file.path;
    var selections = 0;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'pickContactFile');
      selections++;
      return selection;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final wasBlocked = TopBanner.blocked;
    TopBanner.blocked = true;
    addTearDown(() => TopBanner.blocked = wasBlocked);
    await tester.pumpWidget(
      ChangeNotifierProvider<ContactsService>.value(
        value: contacts,
        child: const MaterialApp(home: Scaffold(body: ContactsMatchingTile())),
      ),
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('Import contacts (.vcf)'));
      await contacts.completed.future.timeout(const Duration(seconds: 5));
    });
    await tester.pumpAndSettle();
    expect(contacts.imported, [vcard]);
    selection = null;
    await tester.tap(find.text('Import contacts (.vcf)'));
    await tester.pumpAndSettle();
    expect(selections, 2);
    expect(contacts.imported, [vcard]);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('Linux restores system mode and excludes system colors', (
    tester,
  ) async {
    final store = _SettingsStore();
    store.values['micago.theme.mode'] = 'system';
    store.values['micago.theme.color'] = 'linuxDesktop';
    final theme = ThemeController(store: store);
    addTearDown(theme.dispose);
    await theme.bootstrap();
    expect(theme.themeMode, ThemeMode.system);
    expect(theme.useLinuxTheme, isTrue);
    await theme.setThemeMode(ThemeMode.dark);
    expect(store.values['micago.theme.mode'], 'dark');
    await theme.setThemeMode(ThemeMode.system);
    expect(theme.themeMode, ThemeMode.system);
    expect(store.values['micago.theme.mode'], 'system');
    theme.setSystemColorsAvailable(true);
    expect(
      theme.availableColorChoices,
      isNot(contains(ThemeColorChoice.system)),
    );
    await theme.setColorChoice(ThemeColorChoice.system);
    expect(theme.colorChoice, ThemeColorChoice.micago);
    expect(theme.useSystemColors, isFalse);
    store.values['micago.theme.color'] = 'system';
    await theme.bootstrap();
    expect(theme.colorChoice, ThemeColorChoice.micago);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets(
    'Android restores system mode and falls back from Linux palette',
    (tester) async {
      final store = _SettingsStore();
      store.values['micago.theme.mode'] = 'system';
      store.values['micago.theme.color'] = 'linuxDesktop';
      final theme = ThemeController(store: store);
      addTearDown(theme.dispose);
      await theme.bootstrap();
      expect(theme.themeMode, ThemeMode.system);
      expect(theme.colorChoice, ThemeColorChoice.micago);
      expect(
        theme.availableColorChoices,
        isNot(contains(ThemeColorChoice.linuxDesktop)),
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('Linux exposes actions on right click and keyboard', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LinuxContextActions(
            onOpen: (_) => opened++,
            child: const SizedBox(
              width: 300,
              height: 80,
              child: Text('Message'),
            ),
          ),
        ),
      ),
    );
    expect(
      tester.getSize(find.byType(LinuxContextActions)),
      const Size(300, 80),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.text('Message')));
    await tester.pump();
    expect(find.byIcon(Icons.more_horiz), findsNothing);
    expect(
      tester.getSize(find.byType(LinuxContextActions)),
      const Size(300, 80),
    );
    await tester.tap(find.text('Message'), buttons: kSecondaryMouseButton);
    expect(opened, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    expect(opened, 2);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  Future<AppController> openSettings(WidgetTester tester) async {
    final store = _SettingsStore();
    final app = AppController(store: store);
    final theme = ThemeController(store: store);
    final contacts = ContactsService(store: store);
    final display = MessageDisplayController(store: store);
    addTearDown(app.dispose);
    addTearDown(theme.dispose);
    addTearDown(contacts.dispose);
    addTearDown(display.dispose);
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
        child: const MaterialApp(home: SettingsScreen(separateWindow: true)),
      ),
    );
    await tester.pumpAndSettle();
    return app;
  }

  testWidgets('Linux tray is opt-in and persists only successful changes', (
    tester,
  ) async {
    const desktop = MethodChannel('micago/linux_desktop');
    final calls = <MethodCall>[];
    var fail = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(desktop, (
      call,
    ) async {
      if (fail) throw PlatformException(code: 'tray_failed');
      calls.add(call);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        desktop,
        null,
      ),
    );
    final app = await openSettings(tester);
    final store = app.store as _SettingsStore;
    final toggle = find.text('Keep micaGO in the system tray');
    expect(app.linuxTrayEnabled, isFalse);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(app.linuxTrayEnabled, isTrue);
    expect(store.values['micago.linux.trayEnabled'], '1');
    expect(calls.last.method, 'setTrayEnabled');
    expect(calls.last.arguments['enabled'], isTrue);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(app.linuxTrayEnabled, isFalse);
    expect(store.values['micago.linux.trayEnabled'], '0');
    fail = true;
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(app.linuxTrayEnabled, isFalse);
    expect(store.values['micago.linux.trayEnabled'], '0');
    expect(app.linuxTrayBusy, isFalse);
    await tester.pump(const Duration(seconds: 5));
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('settings window groups existing controls into categories', (
    tester,
  ) async {
    await openSettings(tester);
    expect(find.byType(AppBar), findsNothing);
    expect(find.text('Text size'), findsNothing);
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    expect(find.text('Text size'), findsOneWidget);
    final modeControl = tester.widget<SegmentedButton<ThemeMode>>(
      find.byType(SegmentedButton<ThemeMode>),
    );
    expect(modeControl.segments.map((segment) => segment.value), [
      ThemeMode.system,
      ThemeMode.light,
      ThemeMode.dark,
    ]);
    expect(find.text('Linux'), findsOneWidget);
    await tester.tap(find.text('Contacts'));
    await tester.pumpAndSettle();
    expect(find.text('Import contacts (.vcf)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('settings window adapts its categories to a narrow size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await openSettings(tester);
    expect(
      find.byWidgetPredicate((widget) => widget is DropdownButton),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('Linux replaces sheets with closable desktop dialogs', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppBottomSheet<void>(
                context: context,
                builder: (_) => const Text('Actions'),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('Actions'), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('Android keeps its original sheet and gestures', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => LinuxContextActions(
              onOpen: (_) => opened++,
              child: TextButton(
                onPressed: () => showAppBottomSheet<void>(
                  context: context,
                  builder: (_) => const Text('Actions'),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(opened, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
