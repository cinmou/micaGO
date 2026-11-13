import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/l10n/app_localizations.dart';
import 'package:mica_go/features/chats/message_thread_screen.dart';
import 'package:mica_go/features/chats/models/message_model.dart';

void main() {
  for (final state in [
    LocalSendState.pending,
    LocalSendState.sentUnconfirmed,
    LocalSendState.failed,
  ]) {
    testWidgets('can remove a local ${state.name} send while offline', (
      tester,
    ) async {
      final message = MessageModel.optimistic(
        tempId: 'temp',
        text: 'hello',
        dateCreated: 100,
      ).copyWith(localState: state);
      String? removed;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [MicaLocalizations.delegate],
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showMessageActionMenu(
                  context,
                  message,
                  const Offset(100, 100),
                  onDeletePending: (tempId) async {
                    removed = tempId;
                  },
                ),
                child: const Text('Open menu'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from this device'));
      await tester.pumpAndSettle();

      expect(removed, 'temp');
    });
  }
}
