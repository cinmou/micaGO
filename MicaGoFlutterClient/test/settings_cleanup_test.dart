import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/app_controller.dart';
import 'package:mica_go/core/l10n/app_localizations.dart';
import 'package:mica_go/core/storage/secure_store.dart';
import 'package:mica_go/features/debug/debug_log_panel.dart';
import 'package:mica_go/features/settings/message_display_controller.dart';
import 'package:mica_go/features/settings/message_display_page.dart';
import 'package:provider/provider.dart';

class _Store implements SecureStore {
  final values = <String, String>{};
  @override
  Future<void> writeValue(String key, String value) async =>
      values[key] = value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _App extends AppController {
  _App() : super(store: _Store());
  void reconnectRecorded() {
    realtimeDiagnostics.reconnectCount++;
    notifyListeners();
  }
}

void main() {
  testWidgets('message display note follows the controls', (tester) async {
    final controller = MessageDisplayController(store: _Store());
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          localizationsDelegates: [MicaLocalizations.delegate],
          home: Scaffold(body: MessageDisplayPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final note = find.text('These settings apply to this device.');
    await tester.scrollUntilVisible(note, 150);
    expect(
      tester.getTopLeft(note).dy,
      greaterThan(
        tester.getTopLeft(find.text('Detailed (every outgoing message)')).dy,
      ),
    );
  });

  testWidgets(
    'developer diagnostics show immediately and react without socket events',
    (tester) async {
      final app = _App();
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [MicaLocalizations.delegate],
          home: Scaffold(body: DebugLogPanel(app: app)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ExpansionTile), findsNothing);
      expect(find.text('reconnects: 0'), findsOneWidget);
      app.reconnectRecorded();
      await tester.pump();
      expect(find.text('reconnects: 1'), findsOneWidget);
    },
  );
}
