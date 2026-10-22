import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/l10n/app_localizations.dart';
import 'package:mica_go/features/settings/launcher_icon_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('micago/launcher_icons');
  var current = 'default';
  var failSelection = false;
  final selections = <String>[];

  setUp(() {
    current = 'default';
    failSelection = false;
    selections.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'current') return current;
          if (call.method == 'select') {
            final id = (call.arguments as Map)['icon'] as String;
            selections.add(id);
            if (failSelection) throw PlatformException(code: 'failed');
            current = id;
            return current;
          }
          throw MissingPluginException();
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: [MicaLocalizations.delegate],
        home: Scaffold(body: LauncherIconPicker()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Color? background(WidgetTester tester, String label) => tester
      .widget<OutlinedButton>(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(OutlinedButton),
        ),
      )
      .style!
      .backgroundColor
      ?.resolve({});

  testWidgets('loads all three previews and the native selection on opening', (
    tester,
  ) async {
    current = 'minimal';
    await open(tester);
    expect(find.byType(Image), findsNWidgets(3));
    expect(background(tester, 'Minimal'), isNotNull);
    expect(background(tester, 'Default'), isNull);
    expect(find.text('Classic'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switches among every icon, including back to the new default', (
    tester,
  ) async {
    await open(tester);
    for (final label in ['Classic', 'Minimal', 'Default']) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(background(tester, label), isNotNull);
    }
    expect(selections, ['classic', 'minimal', 'default']);
    expect(current, 'default');
  });

  testWidgets('native failure retains the actual icon and allows retry', (
    tester,
  ) async {
    failSelection = true;
    await open(tester);
    await tester.tap(find.text('Classic'));
    await tester.pumpAndSettle();
    expect(current, 'default');
    expect(background(tester, 'Default'), isNotNull);
    expect(background(tester, 'Classic'), isNull);
    failSelection = false;
    await tester.tap(find.text('Classic'));
    await tester.pumpAndSettle();
    expect(current, 'classic');
    expect(background(tester, 'Classic'), isNotNull);
  });

  testWidgets('does not pretend an unavailable native channel is the default', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw MissingPluginException();
        });
    await open(tester);
    expect(
      find.text('Could not read the current icon. Tap to retry.'),
      findsOneWidget,
    );
    for (final label in ['Default', 'Classic', 'Minimal']) {
      expect(background(tester, label), isNull);
    }
  });
}
