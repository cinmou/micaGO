import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app/theme.dart';
import 'storage/secure_store.dart';

/// Theme color choice. `system` = use Android 12+ dynamic (Material You) colors
/// when available; the rest are fixed seed colors.
enum ThemeColorChoice {
  system,
  micago,
  bicao,
  wisteria,
  citrus,
  blackWhite,
  paleGold,
  wineRed,
  blueGreen,
  indigo,
  dianthus,
  witheredGrass,
  amber,
  liquidGlass,
}

/// Language choice. Null locale follows the system.
enum LanguageChoice { system, english, simplifiedChinese, traditionalChinese }

/// App appearance + language preferences, persisted locally.
class ThemeController extends ChangeNotifier {
  final SecureStore store;

  ThemeController({required this.store});

  ThemeMode themeMode = ThemeMode.system;
  ThemeColorChoice colorChoice = ThemeColorChoice.micago;
  LanguageChoice language = LanguageChoice.system;
  String? chatBackgroundPath;
  bool systemColorsAvailable = false;

  bool get useSystemColors =>
      systemColorsAvailable && colorChoice == ThemeColorChoice.system;
  bool get useBlackWhite => colorChoice == ThemeColorChoice.blackWhite;
  bool get useLiquidGlass => colorChoice == ThemeColorChoice.liquidGlass;
  List<ThemeColorChoice> get availableColorChoices => [
    if (systemColorsAvailable) ThemeColorChoice.system,
    for (final choice in ThemeColorChoice.values)
      if (choice != ThemeColorChoice.system) choice,
  ];

  /// Seed color used when dynamic color is off/unavailable.
  Color get seedColor {
    switch (colorChoice) {
      case ThemeColorChoice.system:
      case ThemeColorChoice.micago:
        return MicaGoTheme.seed;
      case ThemeColorChoice.bicao:
        return const Color(0xFF2E7D32);
      case ThemeColorChoice.wisteria:
        return const Color(0xFF7E6BAE);
      case ThemeColorChoice.citrus:
        return const Color(0xFFE65100);
      case ThemeColorChoice.blackWhite:
        return const Color(0xFF2E2E2E);
      case ThemeColorChoice.paleGold:
        return const Color(0xFFB89B5E);
      case ThemeColorChoice.wineRed:
        return const Color(0xFF8B1E3F);
      case ThemeColorChoice.blueGreen:
        return const Color(0xFF1F6F6A);
      case ThemeColorChoice.indigo:
        return const Color(0xFF2F3A73);
      case ThemeColorChoice.dianthus:
        return const Color(0xFFE889A8);
      case ThemeColorChoice.witheredGrass:
        return const Color(0xFF9C8A4F);
      case ThemeColorChoice.amber:
        return const Color(0xFFB8792B);
      case ThemeColorChoice.liquidGlass:
        return const Color(0xFF007AFF);
    }
  }

  /// Locale override, or null to follow the system.
  Locale? get locale {
    switch (language) {
      case LanguageChoice.system:
        return null;
      case LanguageChoice.english:
        return const Locale('en');
      case LanguageChoice.simplifiedChinese:
        return const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans');
      case LanguageChoice.traditionalChinese:
        return const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');
    }
  }

  static const _kMode = 'micago.theme.mode';
  static const _kColor = 'micago.theme.color';
  static const _kLang = 'micago.theme.lang';
  static const _kChatBackground = 'micago.theme.chatBackgroundPath';

  Future<void> bootstrap() async {
    themeMode = _parseMode(await store.readValue(_kMode));
    colorChoice = _parseColor(await store.readValue(_kColor));
    language = _parseLang(await store.readValue(_kLang));
    chatBackgroundPath = await store.readValue(_kChatBackground);
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    await store.writeValue(_kMode, mode.name);
  }

  Future<void> setColorChoice(ThemeColorChoice choice) async {
    if (choice == ThemeColorChoice.system && !systemColorsAvailable) {
      choice = ThemeColorChoice.micago;
    }
    colorChoice = choice;
    notifyListeners();
    await store.writeValue(_kColor, choice.name);
  }

  void setSystemColorsAvailable(bool available) {
    if (systemColorsAvailable == available &&
        (available || colorChoice != ThemeColorChoice.system)) {
      return;
    }
    systemColorsAvailable = available;
    notifyListeners();
  }

  Future<void> setLanguage(LanguageChoice lang) async {
    language = lang;
    notifyListeners();
    await store.writeValue(_kLang, lang.name);
  }

  Future<void> setChatBackgroundFromFile(String sourcePath) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      return;
    }
    final dir = await getApplicationSupportDirectory();
    final bgDir = Directory(p.join(dir.path, 'chat-backgrounds'));
    await bgDir.create(recursive: true);
    final ext = p.extension(sourcePath).toLowerCase();
    final safeExt = ext.isEmpty ? '.jpg' : ext;
    final dest = File(
      p.join(
        bgDir.path,
        'chat_background_${DateTime.now().millisecondsSinceEpoch}$safeExt',
      ),
    );
    await source.copy(dest.path);
    await _replaceChatBackground(dest.path);
  }

  Future<void> clearChatBackground() => _replaceChatBackground(null);

  Future<void> _replaceChatBackground(String? nextPath) async {
    final previous = chatBackgroundPath;
    chatBackgroundPath = nextPath;
    notifyListeners();
    if (nextPath == null) {
      await store.deleteValue(_kChatBackground);
    } else {
      await store.writeValue(_kChatBackground, nextPath);
    }
    if (previous != null && previous != nextPath) {
      final old = File(previous);
      if (await old.exists()) {
        try {
          await old.delete();
        } catch (_) {}
      }
    }
  }

  ThemeMode _parseMode(String? v) => ThemeMode.values.firstWhere(
    (m) => m.name == v,
    orElse: () => ThemeMode.system,
  );
  ThemeColorChoice _parseColor(String? v) => ThemeColorChoice.values.firstWhere(
    (c) => c.name == v,
    orElse: () => switch (v) {
      'blue' => ThemeColorChoice.micago,
      'green' => ThemeColorChoice.bicao,
      'purple' => ThemeColorChoice.wisteria,
      'orange' => ThemeColorChoice.citrus,
      'suoh' => ThemeColorChoice.wineRed,
      'enshuNezu' => ThemeColorChoice.micago,
      _ => ThemeColorChoice.micago,
    },
  );
  LanguageChoice _parseLang(String? v) {
    if (v == 'chinese') return LanguageChoice.simplifiedChinese;
    return LanguageChoice.values.firstWhere(
      (l) => l.name == v,
      orElse: () => LanguageChoice.system,
    );
  }
}
