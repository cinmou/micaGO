import 'package:flutter_test/flutter_test.dart';

import 'package:mica_go/core/models/connection_profile.dart';
import 'package:mica_go/core/storage/secure_store.dart';
import 'package:mica_go/core/theme_controller.dart';

class _MemoryStore implements SecureStore {
  final Map<String, String> values = {};
  ConnectionProfile? profile;
  bool contactsEnabled = false;

  @override
  Future<void> clearProfile() async {
    profile = null;
  }

  @override
  Future<bool> contactsMatchingEnabled() async => contactsEnabled;

  @override
  Future<void> deleteValue(String key) async {
    values.remove(key);
  }

  @override
  Future<ConnectionProfile?> loadProfile() async => profile;

  @override
  Future<String?> readValue(String key) async => values[key];

  @override
  Future<void> saveProfile(ConnectionProfile profile) async {
    this.profile = profile;
  }

  @override
  Future<void> setContactsMatchingEnabled(bool enabled) async {
    contactsEnabled = enabled;
  }

  @override
  Future<void> writeValue(String key, String value) async {
    values[key] = value;
  }
}

void main() {
  test(
    'micaGO is the default color when dynamic colors are unavailable',
    () async {
      final store = _MemoryStore();
      final theme = ThemeController(store: store);

      await theme.bootstrap();

      expect(theme.colorChoice, ThemeColorChoice.micago);
      expect(theme.useSystemColors, isFalse);
      expect(
        theme.availableColorChoices,
        isNot(contains(ThemeColorChoice.system)),
      );
    },
  );

  test(
    'system color choice is preserved but derives a fallback when dynamic '
    'colors disappear',
    () async {
      final store = _MemoryStore()..values['micago.theme.color'] = 'system';
      final theme = ThemeController(store: store);

      await theme.bootstrap();
      theme.setSystemColorsAvailable(false);

      // The saved 'system' preference is kept (so it's honoured again when
      // dynamic colors return); the effective color falls back via the derived
      // useSystemColors getter without overwriting the stored choice.
      expect(theme.colorChoice, ThemeColorChoice.system);
      expect(theme.useSystemColors, isFalse);
      expect(store.values['micago.theme.color'], 'system');
    },
  );
}
