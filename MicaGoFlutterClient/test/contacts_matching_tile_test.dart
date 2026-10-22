import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/l10n/app_localizations.dart';
import 'package:mica_go/core/storage/secure_store.dart';
import 'package:mica_go/features/contacts/contacts_service.dart';
import 'package:mica_go/features/settings/contacts_matching_tile.dart';
import 'package:provider/provider.dart';

class _Store implements SecureStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Contacts extends ContactsService {
  _Contacts() : super(store: _Store());
  bool supported = true;
  bool allow = true;
  int enables = 0;
  int settingsOpened = 0;
  Completer<void>? disabling;

  @override
  bool get isSupported => supported;

  @override
  Future<void> enable() async {
    enables++;
    status = allow ? ContactsStatus.ready : ContactsStatus.denied;
    notifyListeners();
  }

  @override
  Future<void> disable() async {
    await disabling?.future;
    status = ContactsStatus.disabled;
    notifyListeners();
  }

  @override
  Future<void> openSettings() async => settingsOpened++;
}

void main() {
  Future<void> open(WidgetTester tester, _Contacts contacts) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<ContactsService>.value(
        value: contacts,
        child: const MaterialApp(
          localizationsDelegates: [MicaLocalizations.delegate],
          home: Scaffold(body: Card(child: ContactsMatchingTile())),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('matching toggles inline without opening another page', (
    tester,
  ) async {
    final contacts = _Contacts();
    addTearDown(contacts.dispose);
    await open(tester, contacts);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(contacts.enables, 1);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).subtitle,
      isNull,
    );
    expect(find.byType(Scaffold), findsOneWidget);
  });

  testWidgets('denied access offers system settings beside the same switch', (
    tester,
  ) async {
    final contacts = _Contacts()..allow = false;
    addTearDown(contacts.dispose);
    await open(tester, contacts);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
    expect(
      find.textContaining(
        'Allow contacts access in system settings, then turn matching on.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Open Settings'));
    await tester.pumpAndSettle();
    expect(contacts.settingsOpened, 1);
    contacts.allow = true;
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(contacts.isReady, isTrue);
    expect(find.text('Open Settings'), findsNothing);
  });

  testWidgets('a pending change disables the switch until it completes', (
    tester,
  ) async {
    final contacts = _Contacts()
      ..status = ContactsStatus.ready
      ..disabling = Completer<void>();
    addTearDown(contacts.dispose);
    await open(tester, contacts);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
      isNull,
    );
    contacts.disabling!.complete();
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
      isNotNull,
    );
    expect(contacts.isReady, isFalse);
  });

  testWidgets('platforms without a contacts plugin have no broken entry', (
    tester,
  ) async {
    final contacts = _Contacts()..supported = false;
    addTearDown(contacts.dispose);
    await open(tester, contacts);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(contacts.enables, 0);
  });
}
