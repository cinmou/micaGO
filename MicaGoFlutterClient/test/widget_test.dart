// C0 smoke test: the connection setup screen renders its core fields.
//
// Uses a fake AppController-free path by pumping ConnectionScreen inside a
// Provider with a controller backed by an in-memory store, so no platform
// channels (secure storage) are exercised.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:mica_go/core/app_controller.dart';
import 'package:mica_go/core/models/connection_profile.dart';
import 'package:mica_go/core/storage/secure_store.dart';
import 'package:mica_go/features/connection/connection_screen.dart';

/// In-memory SecureStore stand-in so tests never touch platform channels.
class _MemoryStore implements SecureStore {
  ConnectionProfile? _saved;

  @override
  Future<bool> compatibilityStorageEnabled() async => false;
  @override
  Future<void> prepareCredentialStorage({
    Future<bool> Function()? confirmCompatibility,
  }) async {}

  @override
  Future<ConnectionProfile?> loadProfile() async => _saved;

  @override
  Future<void> saveProfile(ConnectionProfile profile) async {
    _saved = profile;
  }

  @override
  Future<void> clearProfile() async {
    _saved = null;
  }

  bool _contactsEnabled = false;

  @override
  Future<bool> contactsMatchingEnabled() async => _contactsEnabled;

  @override
  Future<void> setContactsMatchingEnabled(bool enabled) async {
    _contactsEnabled = enabled;
  }

  final Map<String, String> _values = {};

  @override
  Future<String?> readValue(String key) async => _values[key];

  @override
  Future<void> writeValue(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> deleteValue(String key) async {
    _values.remove(key);
  }
}

void main() {
  testWidgets(
    'connection screen is QR/paste first and hides low-level WS entry',
    (tester) async {
      final controller = AppController(store: _MemoryStore());

      await tester.pumpWidget(
        ChangeNotifierProvider<AppController>.value(
          value: controller,
          child: const MaterialApp(home: ConnectionScreen()),
        ),
      );

      expect(find.text('Scan QR code'), findsOneWidget);
      expect(find.text('Paste connection JSON'), findsOneWidget);
      expect(find.text('Advanced manual setup'), findsNothing);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.text('WebSocket URL (optional)'), findsNothing);
      expect(find.text('Server URL'), findsNothing);
    },
  );
}
