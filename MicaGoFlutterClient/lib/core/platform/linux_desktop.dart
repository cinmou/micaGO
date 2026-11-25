import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

bool get isLinuxDesktop =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

class LinuxDesktop {
  static const _channel = MethodChannel('micago/linux_desktop');

  static void attachWindowFocusHandler(
    void Function(ui.ViewFocusEvent) onFocus,
  ) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'viewFocus') return;
      final arguments = call.arguments as Map;
      final viewId = arguments['viewId'] as int;
      if (!ui.PlatformDispatcher.instance.views.any(
        (view) => view.viewId == viewId,
      )) {
        return;
      }
      onFocus(
        ui.ViewFocusEvent(
          viewId: viewId,
          state: arguments['focused'] == true
              ? ui.ViewFocusState.focused
              : ui.ViewFocusState.unfocused,
          direction: ui.ViewFocusDirection.undefined,
        ),
      );
    });
  }

  static void detachWindowFocusHandler() => _channel.setMethodCallHandler(null);

  static Future<void> show() async {
    if (!isLinuxDesktop) return;
    await _channel.invokeMethod<void>('show');
  }

  static Future<void> quit() => _channel.invokeMethod<void>('quit');

  static Future<void> ensureCredentialStorage() =>
      _channel.invokeMethod<void>('ensureCredentialStorage');

  static Future<void> setTrayEnabled(
    bool enabled, {
    required String openLabel,
    required String quitLabel,
  }) => _channel.invokeMethod<void>('setTrayEnabled', {
    'enabled': enabled,
    'openLabel': openLabel,
    'quitLabel': quitLabel,
  });

  static Future<void> openSettings(String title) =>
      _channel.invokeMethod<void>('openSettings', {'title': title});

  static Future<void> closeSettings() =>
      _channel.invokeMethod<void>('closeSettings');

  static Future<List<String>> pickFiles(String title) async =>
      await _channel.invokeListMethod<String>('pickFiles', title) ?? const [];

  static Future<String?> pickContactFile(String title) =>
      _channel.invokeMethod<String>('pickContactFile', title);

  /// Reads files or raw image bytes from the Linux clipboard asynchronously
  /// via GTK3 (with Wayland `wl-paste` fallback). Returns `null` when the
  /// clipboard has no file/image payload or when the runner does not implement
  /// the method (e.g. in unit tests).
  static Future<LinuxClipboardAttachments?> readClipboardAttachments() async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'readClipboardAttachments',
      );
      if (raw is! Map) return null;
      final paths = (raw['paths'] as List?)
          ?.whereType<String>()
          .toList(growable: false);
      if (paths != null && paths.isNotEmpty) {
        return LinuxClipboardAttachments(paths: paths);
      }
      final bytes = raw['bytes'];
      if (bytes is Uint8List && bytes.isNotEmpty) {
        return LinuxClipboardAttachments(
          imageBytes: bytes,
          mimeType: raw['mimeType'] as String?,
        );
      }
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

class LinuxClipboardAttachments {
  final List<String> paths;
  final Uint8List? imageBytes;
  final String? mimeType;

  const LinuxClipboardAttachments({
    this.paths = const [],
    this.imageBytes,
    this.mimeType,
  });
}

/// Apply the app preference without discarding the system accessibility scaler.
class DesktopTextScaler extends TextScaler {
  const DesktopTextScaler(this.system, this.factor);
  final TextScaler system;
  final double factor;

  @override
  double scale(double fontSize) => system.scale(fontSize) * factor;

  @override
  double get textScaleFactor => system.scale(14) / 14 * factor;

  @override
  bool operator ==(Object other) =>
      other is DesktopTextScaler &&
      system == other.system &&
      factor == other.factor;

  @override
  int get hashCode => Object.hash(system, factor);
}
