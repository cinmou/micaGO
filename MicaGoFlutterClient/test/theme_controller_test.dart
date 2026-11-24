import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/app/theme.dart';
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
  Future<bool> compatibilityStorageEnabled() async => false;
  @override
  Future<void> prepareCredentialStorage({
    Future<bool> Function()? confirmCompatibility,
  }) async {}

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
  test('compatibility symbols are a global text fallback', () {
    final theme = MicaGoTheme.light();
    expect(
      theme.textTheme.bodyMedium?.fontFamilyFallback,
      contains('MicaGoCompatSymbols'),
    );
  });

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

  test('system color choice is preserved but derives a fallback when dynamic '
      'colors disappear', () async {
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
  });

  test('liquid glass switch persists independently of theme color', () async {
    final store = _MemoryStore();
    final theme = ThemeController(store: store);

    await theme.bootstrap();
    expect(theme.useLiquidGlass, isFalse);
    expect(
      theme.availableColorChoices,
      isNot(contains(ThemeColorChoice.liquidGlass)),
    );

    await theme.setLiquidGlassEnabled(true);
    await theme.setColorChoice(ThemeColorChoice.bicao);

    expect(theme.useLiquidGlass, isTrue);
    expect(theme.colorChoice, ThemeColorChoice.bicao);
    expect(store.values['micago.theme.liquidGlass'], 'true');
    expect(store.values['micago.theme.color'], 'bicao');

    final reloaded = ThemeController(store: store);
    await reloaded.bootstrap();
    expect(reloaded.useLiquidGlass, isTrue);
    expect(reloaded.colorChoice, ThemeColorChoice.bicao);

    await reloaded.setLiquidGlassEnabled(false);
    expect(reloaded.useLiquidGlass, isFalse);
    expect(reloaded.colorChoice, ThemeColorChoice.bicao);
    expect(store.values['micago.theme.liquidGlass'], 'false');
  });

  test('legacy liquidGlass color smoothly migrates on bootstrap and setter',
      () async {
    final store = _MemoryStore()..values['micago.theme.color'] = 'liquidGlass';
    final theme = ThemeController(store: store);

    await theme.bootstrap();

    expect(theme.useLiquidGlass, isTrue);
    expect(theme.colorChoice, ThemeColorChoice.micago);
    expect(store.values['micago.theme.liquidGlass'], 'true');
    expect(store.values['micago.theme.color'], 'micago');

    // Explicitly passing the legacy enum value also enables the switch and
    // normalizes the color choice to micaGO.
    await theme.setLiquidGlassEnabled(false);
    await theme.setColorChoice(ThemeColorChoice.liquidGlass);
    expect(theme.useLiquidGlass, isTrue);
    expect(theme.colorChoice, ThemeColorChoice.micago);
    expect(store.values['micago.theme.liquidGlass'], 'true');
    expect(store.values['micago.theme.color'], 'micago');
  });

  test('liquidGlassScheme follows selected color scheme instead of locking blue',
      () {
    final brandLight = MicaGoTheme.liquidGlassScheme(
      Brightness.light,
      base: ColorScheme.fromSeed(seedColor: MicaGoTheme.seed),
      isBrandDefault: true,
    );
    final brandDark = MicaGoTheme.liquidGlassScheme(
      Brightness.dark,
      base: ColorScheme.fromSeed(
        seedColor: MicaGoTheme.seed,
        brightness: Brightness.dark,
      ),
      isBrandDefault: true,
    );
    expect(brandLight.primary, const Color(0xFF007AFF));
    expect(brandDark.primary, const Color(0xFF0A84FF));
    expect(brandLight.surface, isNot(Colors.white));
    expect(brandDark.surface, isNot(Colors.black));

    final bicaoBase = ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D32));
    final bicaoGlass = MicaGoTheme.liquidGlassScheme(
      Brightness.light,
      base: bicaoBase,
      isBrandDefault: false,
    );
    expect(bicaoGlass.primary, bicaoBase.primary);
    expect(bicaoGlass.onPrimary, bicaoBase.onPrimary);
    expect(bicaoGlass.primary, isNot(const Color(0xFF007AFF)));

    final inkWashDarkBase = MicaGoTheme.blackWhiteScheme(Brightness.dark);
    final inkWashGlass = MicaGoTheme.liquidGlassScheme(
      Brightness.dark,
      base: inkWashDarkBase,
      isBrandDefault: false,
    );
    expect(inkWashGlass.primary, const Color(0xFFFFFFFF));
    expect(inkWashGlass.onPrimary, const Color(0xFF111111));
  });
}
