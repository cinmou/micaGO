import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../../app/router.dart';
import '../../core/app_controller.dart';
import '../../core/l10n/app_localizations.dart';
import 'pairing_controller.dart';
import 'pairing_payload.dart';

/// QR pairing: scan the server's pairing code, preview it, then save + test.
class QrPairingScreen extends StatefulWidget {
  const QrPairingScreen({super.key});

  @override
  State<QrPairingScreen> createState() => _QrPairingScreenState();
}

class _QrPairingScreenState extends State<QrPairingScreen>
    with WidgetsBindingObserver {
  late final PairingController _pairing;
  // C61: ONE controller for the State's whole lifetime (never swapped/recreated
  // — the MobileScanner widget stays bound to its ValueNotifier; disposing it
  // mid-build blanks the preview). autoStart:false + an explicit start() we
  // drive ourselves. Two fixes over C59:
  //   1. Start in a *post-frame* callback, not directly in initState. start()
  //      only waits 500ms for the widget's attach(); driving it from initState
  //      races the first build, and on a slow frame it times out with
  //      `controllerNotAttached` → the camera never opens even with permission
  //      granted (this was the "authorized but can't invoke" symptom). By the
  //      post-frame callback the MobileScanner widget has attached.
  //   2. The resume path no longer gates on `hasCameraPermission`. That getter
  //      is false until the camera has *initialized once*, so the old gate
  //      could never let a first start through after a grant that didn't
  //      restart the process. start() itself no-ops when already running and
  //      re-requests permission when needed, so an unconditional guarded start
  //      is safe.
  final MobileScannerController _scanner = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
    autoStart: false,
  );
  int _cameraStartEpoch = 0;

  @override
  void initState() {
    super.initState();
    _pairing = PairingController(context.read<AppController>());
    WidgetsBinding.instance.addObserver(this);
    // Start after the first frame so the MobileScanner widget has attached
    // its platform view (start() only waits 500ms for that otherwise).
    WidgetsBinding.instance.addPostFrameCallback((_) => _queueCameraStart());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        // Covers "granted from system Settings without a process restart" and
        // returning from the app switcher. start() no-ops if already running.
        if (_pairing.stage == PairingStage.scanning) {
          _queueCameraStart();
        }
        break;
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _cameraStartEpoch++;
        unawaited(_scanner.stop().catchError((_) {}));
        break;
    }
  }

  void _queueCameraStart() {
    final epoch = ++_cameraStartEpoch;
    unawaited(_safeStart(epoch));
  }

  /// start() that survives the widget attach race in mobile_scanner 7.x. When a
  /// custom controller is passed, our State owns the lifecycle and start() may
  /// run before MobileScanner has completed attach(); retry those short races
  /// instead of leaving the scanner blank forever.
  Future<void> _safeStart(int epoch, {int attempt = 0}) async {
    if (!mounted || epoch != _cameraStartEpoch) return;
    if (_pairing.stage != PairingStage.scanning) return;
    try {
      await _scanner.start();
    } on MobileScannerException catch (error) {
      if (!_shouldRetryStart(error, attempt)) return;
      await Future<void>.delayed(Duration(milliseconds: 120 * (attempt + 1)));
      await _safeStart(epoch, attempt: attempt + 1);
    } catch (_) {
      if (attempt >= 3) return;
      await Future<void>.delayed(Duration(milliseconds: 120 * (attempt + 1)));
      await _safeStart(epoch, attempt: attempt + 1);
    }
  }

  bool _shouldRetryStart(MobileScannerException error, int attempt) {
    if (attempt >= 5) return false;
    switch (error.errorCode) {
      case MobileScannerErrorCode.controllerNotAttached:
      case MobileScannerErrorCode.controllerAlreadyInitialized:
      case MobileScannerErrorCode.controllerInitializing:
      case MobileScannerErrorCode.genericError:
        return true;
      case MobileScannerErrorCode.controllerDisposed:
      case MobileScannerErrorCode.controllerUninitialized:
      case MobileScannerErrorCode.permissionDenied:
      case MobileScannerErrorCode.unsupported:
        return false;
    }
  }

  @override
  void dispose() {
    _cameraStartEpoch++;
    WidgetsBinding.instance.removeObserver(this);
    _pairing.dispose();
    super.dispose();
    // Per the docs: dispose the controller after super.dispose(), so the
    // MobileScanner widget detaches before its controller goes away.
    unawaited(_scanner.dispose());
  }

  void _onDetect(BarcodeCapture capture) {
    if (_pairing.stage != PairingStage.scanning) return;
    String? raw;
    for (final b in capture.barcodes) {
      if ((b.rawValue ?? '').isNotEmpty) {
        raw = b.rawValue;
        break;
      }
    }
    if (raw == null) return;

    _pairing.onScan(raw);
    if (_pairing.stage == PairingStage.preview) {
      _scanner.stop();
    } else if (_pairing.message != null && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_pairing.message!)));
    }
  }

  Future<void> _useScanned() async {
    final ok = await _pairing.useScanned();
    if (ok && mounted) {
      context.go(Routes.home);
    }
  }

  void _scanAgain() {
    _pairing.scanAgain();
    unawaited(_restartCamera());
  }

  // Retry button / scan-again: a plain stop → start on the long-lived
  // controller, exactly as the mobile_scanner docs do on resume. start() re-runs
  // the permission check, so this also recovers the "granted while the app was
  // alive" case without ever swapping the controller out from under the widget.
  Future<void> _restartCamera() async {
    final epoch = ++_cameraStartEpoch;
    try {
      await _scanner.stop();
    } catch (_) {
      // Not started yet — fine, just start below.
    }
    await _safeStart(epoch);
  }

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.t('pair.scanTitle')),
        actions: [
          IconButton(
            tooltip: strings.t('pair.toggleTorch'),
            icon: const Icon(Icons.flashlight_on_outlined),
            onPressed: () => _scanner.toggleTorch(),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _pairing,
        builder: (context, _) {
          switch (_pairing.stage) {
            case PairingStage.scanning:
              return _scannerView();
            case PairingStage.preview:
              return _PreviewPane(
                payload: _pairing.payload!,
                pairing: _pairing,
                onUse: _useScanned,
                onScanAgain: _scanAgain,
              );
            case PairingStage.testing:
              return _CenteredStatus(
                icon: null,
                text: strings.t('pair.connecting'),
                showSpinner: true,
              );
            case PairingStage.failure:
              return _FailurePane(
                message: _pairing.message ?? strings.t('pair.failed'),
                onScanAgain: _scanAgain,
                onRetry: _useScanned,
              );
            case PairingStage.success:
              return _CenteredStatus(
                icon: Icons.check_circle_outline,
                text: strings.t('pair.paired'),
                showSpinner: false,
              );
          }
        },
      ),
    );
  }

  Widget _scannerView() {
    return Stack(
      alignment: Alignment.center,
      children: [
        MobileScanner(
          controller: _scanner,
          onDetect: _onDetect,
          errorBuilder: (context, error) =>
              _CameraError(error: error, onRetry: _restartCamera),
        ),
        // Simple framing + hint overlay.
        IgnorePointer(
          child: Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.9),
                width: 3,
              ),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
        Positioned(
          bottom: 32,
          left: 24,
          right: 24,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                MicaLocalizations.of(context).t('pair.scanHint'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 12),
              // C23: the one alternative to scanning — paste the connection JSON
              // copied from the Mac app. No LAN-only vs LAN+Public choice.
              FilledButton.tonalIcon(
                onPressed: _pasteConnectionJson,
                icon: const Icon(Icons.content_paste),
                label: Text(MicaLocalizations.of(context).t('pair.pasteJson')),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _pasteConnectionJson() async {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final controller = TextEditingController(text: clip?.text?.trim() ?? '');
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(MicaLocalizations.of(ctx).t('pair.pasteJson')),
        content: TextField(
          controller: controller,
          maxLines: 6,
          autofocus: true,
          decoration: InputDecoration(
            hintText: MicaLocalizations.of(ctx).t('pair.pasteJsonHint'),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(MicaLocalizations.of(ctx).t('settings.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text(MicaLocalizations.of(ctx).t('pair.connect')),
          ),
        ],
      ),
    );
    if (raw != null && raw.isNotEmpty) _pairing.onScan(raw);
  }
}

class _CameraError extends StatelessWidget {
  final MobileScannerException error;
  final Future<void> Function() onRetry;
  const _CameraError({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_outlined, size: 48),
            const SizedBox(height: 12),
            Text(
              strings.t('pair.cameraUnavailable'),
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              strings.t('pair.cameraHelp'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: () => onRetry(),
              icon: const Icon(Icons.refresh),
              label: Text(strings.t('pair.cameraRetry')),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewPane extends StatelessWidget {
  final PairingPayload payload;
  final PairingController pairing;
  final VoidCallback onUse;
  final VoidCallback onScanAgain;

  const _PreviewPane({
    required this.payload,
    required this.pairing,
    required this.onUse,
    required this.onScanAgain,
  });

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.qr_code_2),
                      const SizedBox(width: 8),
                      Text(
                        strings.t('pair.codeFound'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _kv(context, strings.t('pair.serverUrl'), payload.baseUrl),
                  const SizedBox(height: 6),
                  _kv(
                    context,
                    strings.t('pair.websocket'),
                    payload.effectiveWsUrl,
                  ),
                  const SizedBox(height: 6),
                  _kv(
                    context,
                    strings.t('pair.token'),
                    _maskedToken(payload.token),
                  ),
                  if (payload.serverName != null) ...[
                    const SizedBox(height: 6),
                    _kv(context, strings.t('pair.server'), payload.serverName!),
                  ],
                ],
              ),
            ),
          ),
          // C23 cleanup: no LAN-only vs LAN+Public mode picker. The unified
          // connection always tries LAN first, then Public as an optional
          // fallback — the client decides automatically.
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onUse,
            icon: const Icon(Icons.check),
            label: Text(strings.t('pair.useThisServer')),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: onScanAgain,
            icon: const Icon(Icons.qr_code_scanner),
            label: Text(strings.t('pair.scanAgain')),
          ),
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 92,
          child: Text(
            k,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            v,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
      ],
    );
  }

  /// Masks the token (shown only as a short prefix). Never reveals it fully.
  String _maskedToken(String token) {
    if (token.isEmpty) return '—';
    final head = token.length <= 4 ? token : token.substring(0, 4);
    return '$head••••••••';
  }
}

class _FailurePane extends StatelessWidget {
  final String message;
  final VoidCallback onScanAgain;
  final VoidCallback onRetry;

  const _FailurePane({
    required this.message,
    required this.onScanAgain,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: onRetry,
              child: Text(MicaLocalizations.of(context).t('pair.tryAgain')),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: onScanAgain,
              child: Text(
                MicaLocalizations.of(context).t('pair.scanDifferent'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CenteredStatus extends StatelessWidget {
  final IconData? icon;
  final String text;
  final bool showSpinner;

  const _CenteredStatus({
    required this.icon,
    required this.text,
    required this.showSpinner,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showSpinner) const CircularProgressIndicator(),
          if (icon != null) Icon(icon, size: 48),
          const SizedBox(height: 16),
          Text(text),
        ],
      ),
    );
  }
}
