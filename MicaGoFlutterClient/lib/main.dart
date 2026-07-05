import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app/mica_go_app.dart';
import 'core/app_controller.dart';
import 'core/network/push_service.dart';
import 'core/storage/secure_store.dart';
import 'core/theme_controller.dart';
import 'features/contacts/contacts_service.dart';
import 'features/settings/message_display_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerMicaGoFirebaseBackgroundHandler();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('[Startup] FlutterError: ${details.exception}');
    if (details.stack != null) {
      debugPrintStack(stackTrace: details.stack);
    }
  };
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('[Startup] Platform error: $error');
    debugPrintStack(stackTrace: stack);
    return true;
  };
  await _startupStep(
    'LiquidGlassWidgets.initialize',
    () => LiquidGlassWidgets.initialize(),
    timeout: const Duration(seconds: 2),
  );

  final store = SecureStore();
  final controller = AppController(store: store);
  final contacts = ContactsService(store: store);
  final theme = ThemeController(store: store);
  final messageDisplay = MessageDisplayController(store: store);

  await _startupStep(
    'AppController.bootstrap',
    controller.bootstrap,
    timeout: const Duration(seconds: 6),
  );
  await _startupStep(
    'ContactsService.bootstrap',
    contacts.bootstrap,
    timeout: const Duration(seconds: 3),
  );
  await _startupStep(
    'ThemeController.bootstrap',
    theme.bootstrap,
    timeout: const Duration(seconds: 2),
  );
  await _startupStep(
    'MessageDisplayController.bootstrap',
    messageDisplay.bootstrap,
    timeout: const Duration(seconds: 2),
  );

  // C31: let the controller title local notifications with on-device contact
  // names (resolves live against the contacts index; null when matching is off).
  controller.contactNameResolver = contacts.displayNameFor;
  controller.contactIdResolver = contacts.contactIdFor;
  // C32: and show the contact's avatar in the notification when available.
  controller.contactAvatarResolver = contacts.thumbnailForHandle;

  runApp(
    MicaGoApp(
      controller: controller,
      contacts: contacts,
      theme: theme,
      messageDisplay: messageDisplay,
    ),
  );
}

Future<void> _startupStep(
  String name,
  Future<void> Function() run, {
  required Duration timeout,
}) async {
  final started = DateTime.now();
  debugPrint('[Startup] $name started');
  try {
    await run().timeout(timeout);
    final elapsed = DateTime.now().difference(started).inMilliseconds;
    debugPrint('[Startup] $name completed in ${elapsed}ms');
  } on TimeoutException {
    debugPrint('[Startup] $name timed out after ${timeout.inMilliseconds}ms');
  } catch (error, stack) {
    debugPrint('[Startup] $name failed: $error');
    debugPrintStack(stackTrace: stack);
  }
}
