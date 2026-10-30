import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

/// C37: records a voice message to a temp AAC/m4a file and returns its bytes, so
/// the existing send-attachment path can ship it (the server sends arbitrary
/// files via AppleScript). Mic permission is requested on first record. Failures
/// are surfaced as a null result rather than thrown — the caller shows a banner.
class VoiceRecorder {
  final AudioRecorder _rec = AudioRecorder();
  String? _path;
  Timer? _ticker;
  Timer? _ampTicker;

  /// Elapsed recording time, for the UI timer.
  final ValueNotifier<Duration> elapsed = ValueNotifier(Duration.zero);
  final ValueNotifier<List<double>> levels = ValueNotifier(<double>[]);

  /// Starts recording. Returns false when the mic permission is denied or the
  /// recorder can't start (no crash, no partial file left behind).
  Future<bool> start() async {
    try {
      if (!await _rec.hasPermission()) return false;
      final path =
          '${Directory.systemTemp.path}/micago_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _rec.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path,
      );
      _path = path;
      elapsed.value = Duration.zero;
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        elapsed.value += const Duration(seconds: 1);
      });
      _ampTicker = Timer.periodic(const Duration(milliseconds: 90), (_) async {
        try {
          final amp = await _rec.getAmplitude();
          final db = amp.current.isFinite ? amp.current : -60.0;
          final normalized = ((db + 60) / 60).clamp(0.04, 1.0).toDouble();
          final next = [...levels.value, normalized];
          if (next.length > 44) next.removeRange(0, next.length - 44);
          levels.value = next;
        } catch (_) {
          // Amplitude is best-effort; recording itself can continue.
        }
      });
      return true;
    } catch (_) {
      _path = null;
      return false;
    }
  }

  /// Stops and returns the recorded bytes + a filename, or null on failure.
  Future<({Uint8List bytes, String filename})?> stop() async {
    _ticker?.cancel();
    _ampTicker?.cancel();
    String? path;
    try {
      path = await _rec.stop();
    } catch (_) {
      path = _path;
    }
    path ??= _path;
    _path = null;
    if (path == null) return null;
    try {
      final file = File(path);
      final bytes = await file.readAsBytes();
      try {
        await file.delete();
      } catch (_) {
        /* best-effort cleanup */
      }
      if (bytes.isEmpty) return null;
      return (
        bytes: bytes,
        filename: 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a',
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> cancel() async {
    _ticker?.cancel();
    _ampTicker?.cancel();
    try {
      await _rec.cancel();
    } catch (_) {
      /* ignore */
    }
    _path = null;
  }

  void dispose() {
    _ticker?.cancel();
    _ampTicker?.cancel();
    _rec.dispose();
    elapsed.dispose();
    levels.dispose();
  }
}
