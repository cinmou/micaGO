import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/features/settings/settings_dialog_actions.dart';

void main() {
  testWidgets('settings dialog buttons have matching heights', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SettingsDialogActionRow(
              cancelLabel: 'Cancel',
              onCancel: () {},
              confirmLabel: 'Confirm',
              onConfirm: () {},
            ),
          ),
        ),
      ),
    );

    final outlined = tester.getSize(find.byType(OutlinedButton));
    final filled = tester.getSize(find.byType(FilledButton));
    expect(outlined.height, 48);
    expect(filled.height, outlined.height);
  });
}
