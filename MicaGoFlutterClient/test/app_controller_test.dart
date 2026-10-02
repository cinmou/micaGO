import 'package:flutter_test/flutter_test.dart';

import 'package:mica_go/core/app_controller.dart';
import 'package:mica_go/core/models/connection_profile.dart';
import 'package:mica_go/core/storage/secure_store.dart';
import 'package:mica_go/core/network/connection_candidate.dart';

class _MemoryStore implements SecureStore {
  ConnectionProfile? _saved;
  final Map<String, String> _values = {};
  bool _contactsEnabled = false;

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

  @override
  Future<bool> contactsMatchingEnabled() async => _contactsEnabled;

  @override
  Future<void> setContactsMatchingEnabled(bool enabled) async {
    _contactsEnabled = enabled;
  }

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
  test(
    'retry after secure save failure reuses the redeemed device credential',
    () async {
      final store = _FailOnceStore();
      final app = _PairingApp(store: store);
      addTearDown(app.dispose);
      final invitation = ConnectionProfile(
        baseUrl: 'https://relay.example',
        token: 'invitation',
        pairingCode: 'invitation',
      );
      await expectLater(
        app.saveAndActivate(invitation),
        throwsA(isA<CredentialStorageException>()),
      );
      expect(app.profile, isNull);
      expect(app.redemptions, 1);
      await app.saveAndActivate(invitation);
      expect(app.redemptions, 1);
      expect(app.profile!.deviceId, 'test-device');
      expect(store._saved!.pairingCode, isNull);
      expect(store._saved!.token, 'test-device-credential');
    },
  );

  test('batch mute applies to every route in a merged conversation', () async {
    final controller = AppController(store: _MemoryStore());
    const routes = ['iMessage;+1', 'iMessage;email@example.com', 'SMS;+1'];

    expect(controller.areChatsMuted(routes), isFalse);

    await controller.setChatsMuted(routes, true);
    expect(controller.areChatsMuted(routes), isTrue);
    for (final route in routes) {
      expect(controller.isChatMuted(route), isTrue);
    }

    await controller.setChatsMuted(routes, false);
    expect(controller.areChatsMuted(routes), isFalse);
    for (final route in routes) {
      expect(controller.isChatMuted(route), isFalse);
    }
  });
}

class _FailOnceStore extends _MemoryStore {
  int attempts = 0;
  @override
  Future<void> saveProfile(ConnectionProfile profile) async {
    if (++attempts == 1) throw const CredentialStorageException();
    await super.saveProfile(profile);
  }
}

class _PairingApp extends AppController {
  _PairingApp({required super.store});
  int redemptions = 0;
  @override
  Future<ConnectionProfile> redeemPairingProfile(
    ConnectionProfile profile,
  ) async {
    redemptions++;
    return profile.copyWith(
      token: 'test-device-credential',
      deviceId: 'test-device',
      pairingCode: null,
    );
  }

  @override
  Future<bool> selectReachableCandidate({
    required String reason,
    ConnectionCandidateKind? skipKind,
  }) async => true;
}
