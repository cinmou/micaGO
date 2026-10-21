import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:provider/provider.dart';

import '../core/app_controller.dart';
import '../core/l10n/app_localizations.dart';
import '../core/theme_controller.dart';
import '../features/contacts/contacts_service.dart';
import '../features/settings/message_display_controller.dart';
import 'router.dart';
import 'theme.dart';

/// Root widget: provides controllers and wires Material 3 themes (with Android
/// 12+ dynamic color) + locale + router.
class MicaGoApp extends StatefulWidget {
  final AppController controller;
  final ContactsService contacts;
  final ThemeController theme;
  final MessageDisplayController messageDisplay;

  const MicaGoApp({
    super.key,
    required this.controller,
    required this.contacts,
    required this.theme,
    required this.messageDisplay,
  });

  @override
  State<MicaGoApp> createState() => _MicaGoAppState();
}

class _MicaGoAppState extends State<MicaGoApp> {
  late final GoRouter _router = createRouter(widget.controller);

  @override
  void initState() {
    super.initState();
    widget.contacts.addListener(_refreshNotificationContacts);
    _refreshNotificationContacts();
  }

  void _refreshNotificationContacts() {
    if (widget.contacts.status == ContactsStatus.requesting) return;
    unawaited(widget.controller.refreshNotificationContactCache());
  }

  @override
  void dispose() {
    widget.contacts.removeListener(_refreshNotificationContacts);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppController>.value(value: widget.controller),
        ChangeNotifierProvider<ContactsService>.value(value: widget.contacts),
        ChangeNotifierProvider<ThemeController>.value(value: widget.theme),
        ChangeNotifierProvider<MessageDisplayController>.value(
          value: widget.messageDisplay,
        ),
      ],
      child: Consumer<ThemeController>(
        builder: (context, theme, _) {
          return DynamicColorBuilder(
            builder: (lightDynamic, darkDynamic) {
              final dynamicAvailable = lightDynamic != null;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  theme.setSystemColorsAvailable(dynamicAvailable);
                }
              });
              final useDynamic = theme.useSystemColors && dynamicAvailable;
              final useBlackWhite = theme.useBlackWhite;
              final useLiquidGlass = theme.useLiquidGlass;
              final lightScheme = useBlackWhite
                  ? MicaGoTheme.blackWhiteScheme(Brightness.light)
                  : useLiquidGlass
                  ? MicaGoTheme.liquidGlassScheme(Brightness.light)
                  : useDynamic
                  ? lightDynamic.harmonized()
                  : ColorScheme.fromSeed(seedColor: theme.seedColor);
              final darkScheme = useBlackWhite
                  ? MicaGoTheme.blackWhiteScheme(Brightness.dark)
                  : useLiquidGlass
                  ? MicaGoTheme.liquidGlassScheme(Brightness.dark)
                  : (useDynamic && darkDynamic != null)
                  ? darkDynamic.harmonized()
                  : ColorScheme.fromSeed(
                      seedColor: theme.seedColor,
                      brightness: Brightness.dark,
                    );

              return LiquidGlassWidgets.wrap(
                adaptiveQuality: true,
                theme: GlassThemeData.simple(
                  blur: 8,
                  thickness: 32,
                  chromaticAberration: 0.012,
                  lightIntensity: 0.62,
                  saturation: 1.28,
                  borderRadius: 28,
                  quality: GlassQuality.standard,
                ),
                child: MaterialApp.router(
                  title: 'micaGO',
                  debugShowCheckedModeBanner: false,
                  theme: MicaGoTheme.fromScheme(lightScheme),
                  darkTheme: MicaGoTheme.fromScheme(darkScheme),
                  themeMode: theme.themeMode,
                  locale: theme.locale,
                  supportedLocales: const [
                    Locale('en'),
                    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
                    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
                  ],
                  localizationsDelegates: const [
                    MicaLocalizations.delegate,
                    GlobalMaterialLocalizations.delegate,
                    GlobalWidgetsLocalizations.delegate,
                    GlobalCupertinoLocalizations.delegate,
                  ],
                  routerConfig: _router,
                ),
              );
            },
          );
        },
      ),
    );
  }
}
