import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Loads Android's dynamically updated system emoji font (e.g. Google's Noto 3D
/// Emoji delivered into `/data/fonts/` on Android 17+) into Flutter's engine.
///
/// Flutter's Android font manager reads static `/system/etc/fonts.xml`, missing
/// fonts installed via Android's updatable system font mechanism. Native IMEs
/// such as Gboard query `SystemFonts.getAvailableFonts()` and render the 3D
/// font while Flutter falls back to the older 2D font in `/system/fonts/`.
class AndroidUpdatedEmojiFont {
  static const String familyName = 'AndroidUpdatedEmoji';
  static const MethodChannel _channel = MethodChannel('micago/system_fonts');
  static const int _maxFontBytes = 250 * 1024 * 1024;

  static final ValueNotifier<String?> loadedFamily = ValueNotifier<String?>(
    null,
  );
  static Future<String?>? _inflight;

  /// Probes Android for an updated system emoji font and registers it with
  /// [FontLoader]. Safe to call unconditionally: returns `null` on non-Android
  /// platforms or when no updatable emoji font is present.
  static Future<String?> loadIfAvailable({
    bool? isAndroidOverride,
    Future<String?> Function()? findFontPath,
    Future<Uint8List> Function(String path)? readBytes,
    Future<void> Function(String family, Uint8List bytes)? registerFont,
  }) {
    final isAndroid = isAndroidOverride ?? (!kIsWeb && Platform.isAndroid);
    if (!isAndroid) return Future.value(null);
    if (loadedFamily.value != null) return Future.value(loadedFamily.value);
    if (_inflight != null && findFontPath == null) return _inflight!;

    final task = _load(
      findFontPath: findFontPath ?? _defaultFindFontPath,
      readBytes: readBytes ?? _defaultReadBytes,
      registerFont: registerFont ?? _defaultRegisterFont,
    );
    if (findFontPath == null) {
      _inflight = task;
    }
    return task;
  }

  static Future<String?> _load({
    required Future<String?> Function() findFontPath,
    required Future<Uint8List> Function(String path) readBytes,
    required Future<void> Function(String family, Uint8List bytes) registerFont,
  }) async {
    try {
      final path = (await findFontPath())?.trim();
      if (path == null || path.isEmpty) return null;
      final bytes = await readBytes(path);
      if (bytes.isEmpty || bytes.length > _maxFontBytes) return null;
      await registerFont(familyName, bytes);
      loadedFamily.value = familyName;
      return familyName;
    } catch (error) {
      debugPrint('[EmojiFont] Skipping updated Android emoji font: $error');
      return null;
    }
  }

  static Future<String?> _defaultFindFontPath() =>
      _channel.invokeMethod<String>('getUpdatedEmojiFontPath');

  static Future<Uint8List> _defaultReadBytes(String path) async {
    final file = File(path);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file ||
        stat.size <= 0 ||
        stat.size > _maxFontBytes) {
      return Uint8List(0);
    }
    return file.readAsBytes();
  }

  static Future<void> _defaultRegisterFont(
    String family,
    Uint8List bytes,
  ) async {
    final loader = FontLoader(family);
    loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    await loader.load();
  }

  @visibleForTesting
  static void resetForTest() {
    _inflight = null;
    loadedFamily.value = null;
  }
}
