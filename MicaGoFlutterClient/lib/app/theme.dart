import 'package:flutter/material.dart';

/// MicaGo branding + Material 3 light/dark themes.
class MicaGoTheme {
  MicaGoTheme._();

  /// Brand seed color. Also the fallback when system dynamic color is unavailable.
  static const Color seed = Color(0xFF007AFF);

  static ThemeData light() => fromSeed(seed, Brightness.light);
  static ThemeData dark() => fromSeed(seed, Brightness.dark);

  /// Builds a theme from a seed color (used when dynamic color is off).
  static ThemeData fromSeed(Color seedColor, Brightness brightness) =>
      fromScheme(
        ColorScheme.fromSeed(seedColor: seedColor, brightness: brightness),
      );

  /// Builds a theme from a ready-made [ColorScheme] (used for Android 12+
  /// dynamic / Material You colors).
  static ThemeData fromScheme(ColorScheme scheme) {
    final inkWash =
        (scheme.primary == const Color(0xFF111111) &&
            scheme.brightness == Brightness.light) ||
        (scheme.primary == const Color(0xFFFFFFFF) &&
            scheme.brightness == Brightness.dark);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamilyFallback: const ['MicaGoCompatSymbols'],
      appBarTheme: const AppBarTheme(centerTitle: false),
      iconButtonTheme: inkWash
          ? IconButtonThemeData(
              style: IconButton.styleFrom(
                foregroundColor: scheme.onSurface,
                disabledForegroundColor: scheme.onSurface.withValues(
                  alpha: 0.34,
                ),
              ),
            )
          : null,
      cardTheme: CardThemeData(
        clipBehavior: Clip.antiAlias,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      popupMenuTheme: PopupMenuThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          backgroundColor: inkWash ? scheme.primary : null,
          foregroundColor: inkWash ? scheme.onPrimary : null,
          disabledBackgroundColor: inkWash
              ? scheme.surfaceContainerHighest
              : null,
          disabledForegroundColor: inkWash
              ? scheme.onSurface.withValues(alpha: 0.42)
              : null,
        ),
      ),
    );
  }

  static ColorScheme blackWhiteScheme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return (dark ? const ColorScheme.dark() : const ColorScheme.light())
        .copyWith(
          primary: dark ? const Color(0xFFFFFFFF) : const Color(0xFF111111),
          onPrimary: dark ? const Color(0xFF111111) : const Color(0xFFFFFFFF),
          primaryContainer: dark
              ? const Color(0xFF3A3A3A)
              : const Color(0xFFEAEAEA),
          onPrimaryContainer: dark
              ? const Color(0xFFFFFFFF)
              : const Color(0xFF111111),
          secondary: dark ? const Color(0xFFE6E6E6) : const Color(0xFF3A3A3A),
          onSecondary: dark ? const Color(0xFF111111) : const Color(0xFFFFFFFF),
          secondaryContainer: dark
              ? const Color(0xFF303030)
              : const Color(0xFFEDEDED),
          onSecondaryContainer: dark
              ? const Color(0xFFFFFFFF)
              : const Color(0xFF111111),
          tertiary: dark ? const Color(0xFFFFFFFF) : const Color(0xFF555555),
          onTertiary: dark ? const Color(0xFF111111) : const Color(0xFFFFFFFF),
          tertiaryContainer: dark
              ? const Color(0xFF3A3A3A)
              : const Color(0xFFE0E0E0),
          onTertiaryContainer: dark
              ? const Color(0xFFFFFFFF)
              : const Color(0xFF111111),
          error: dark ? const Color(0xFFFFB4AB) : const Color(0xFFB3261E),
          onError: dark ? const Color(0xFF690005) : const Color(0xFFFFFFFF),
          surface: dark ? const Color(0xFF000000) : const Color(0xFFFFFFFF),
          onSurface: dark ? const Color(0xFFFFFFFF) : const Color(0xFF111111),
          surfaceContainerLowest: dark
              ? const Color(0xFF000000)
              : const Color(0xFFFFFFFF),
          surfaceContainerLow: dark
              ? const Color(0xFF0A0A0A)
              : const Color(0xFFF7F7F7),
          surfaceContainer: dark
              ? const Color(0xFF101010)
              : const Color(0xFFF4F4F4),
          surfaceContainerHigh: dark
              ? const Color(0xFF181818)
              : const Color(0xFFEDEDED),
          surfaceContainerHighest: dark
              ? const Color(0xFF242424)
              : const Color(0xFFE0E0E0),
          onSurfaceVariant: dark
              ? const Color(0xFFE0E0E0)
              : const Color(0xFF444444),
          outline: dark ? const Color(0xFF8A8A8A) : const Color(0xFF9A9A9A),
          outlineVariant: dark
              ? const Color(0xFF444444)
              : const Color(0xFFD0D0D0),
          inverseSurface: dark
              ? const Color(0xFFF2F2F2)
              : const Color(0xFF202020),
          onInverseSurface: dark
              ? const Color(0xFF111111)
              : const Color(0xFFFFFFFF),
          inversePrimary: dark
              ? const Color(0xFF111111)
              : const Color(0xFFEDEDED),
          shadow: const Color(0xFF000000),
          scrim: const Color(0xFF000000),
          surfaceTint: Colors.transparent,
        );
  }

  static ColorScheme liquidGlassScheme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final surface = dark ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
    final surfaceHigh = dark
        ? const Color(0xFF1C1C1E)
        : const Color(0xFFFFFFFF);
    final onSurface = dark ? const Color(0xFFF5F5F7) : const Color(0xFF111827);
    final onSurfaceVariant = dark
        ? const Color(0xFFC7C7CC)
        : const Color(0xFF4B5563);
    final incoming = dark ? const Color(0xEE1C1C1E) : const Color(0xEFFFFFFF);
    final onIncoming = dark ? const Color(0xFFF5F5F7) : const Color(0xFF111827);
    return ColorScheme.fromSeed(
      seedColor: const Color(0xFF007AFF),
      brightness: brightness,
    ).copyWith(
      primary: const Color(0xFF007AFF),
      onPrimary: Colors.white,
      primaryContainer: dark
          ? const Color(0xFF0B3D77)
          : const Color(0xFFD7EAFF),
      onPrimaryContainer: dark
          ? const Color(0xFFEAF4FF)
          : const Color(0xFF002D5C),
      secondary: incoming,
      onSecondary: onIncoming,
      secondaryContainer: incoming,
      onSecondaryContainer: onIncoming,
      tertiary: const Color(0xFF007AFF),
      onTertiary: Colors.white,
      surface: surface,
      surfaceContainerLowest: surface,
      surfaceContainerLow: surface,
      surfaceContainer: surface,
      surfaceContainerHigh: surfaceHigh,
      surfaceContainerHighest: surfaceHigh,
      onSurface: onSurface,
      onSurfaceVariant: onSurfaceVariant,
      outlineVariant: dark ? const Color(0x665A5A5F) : const Color(0x66B7C7DA),
      surfaceTint: Colors.transparent,
    );
  }
}
