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

  // C62 scanner rewrite. Root cause of every earlier "authorized but the
  // camera never opens": *we* drove start() from this State (initState /
  // post-frame / retry loops), racing the MobileScanner widget's attach and
  // permission flow, and a swallowed start() exception left a permanent black
  // preview with no error UI.
  //
  // New model — the widget owns the camera session, we own recovery:
  //  * `autoStart: true` (the plugin default): MobileScanner itself calls
  //    start() right after it attaches in its own initState, and stop() in
  //    its dispose. We never call start() at screen-open, so there is no
  //    attach race. Leaving the scanning stage unmounts the widget (stops
  //    the camera); re-entering mounts it again (starts it).
  //  * Platform start failures are caught inside the controller and land in
  //    `value.error` → the errorBuilder card, which now also shows the real
  //    error code, so a failure is diagnosable instead of a black box.
  //  * Retry is a **cold restart**: a brand-new controller under a new
  //    ValueKey. The old widget must unmount before its controller is
  //    disposed (rebinding a live widget blanks the preview — C59), and the
  //    platform channel is a singleton whose dispose() stops the active
  //    camera, so the two sessions are strictly sequenced: unmount old →
  //    dispose old → mount new. The fresh start() re-runs the permission
  //    check, which also recovers "granted in system Settings while the app
  //    stayed alive".
  MobileScannerController? _scanner;
  int _scannerGeneration = 0;

  static MobileScannerController _newScanner() => MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );

  @override
  void initState() {
    super.initState();
    _pairing = PairingController(context.read<AppController>());
    WidgetsBinding.instance.addObserver(this);
    _scanner = _newScanner();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // MobileScanner only self-manages app lifecycle for its own internal
    // controller; with an external controller that's this State's job.
    final scanner = _scanner;
    if (scanner == null) return;
    switch (state) {
      case AppLifecycleState.resumed:
        // start() no-ops when already running and re-runs the permission
        // check when not; in-flight races throw and are swallowed — real
        // failures surface through the errorBuilder.
        if (_pairing.stage == PairingStage.scanning) {
          unawaited(scanner.start().catchError((_) {}));
        }
        break;
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        unawaited(scanner.stop().catchError((_) {}));
        break;
    }
  }

  /// Cold restart for the Retry button: unmount the old scanner widget,
  /// dispose its controller, then mount a fresh controller under a new key —
  /// strictly sequential so two camera sessions never overlap.
  Future<void> _remountScanner() async {
    final old = _scanner;
    if (old == null) return; // A swap is already in flight.
    setState(() => _scanner = null); // Unmounts the old MobileScanner.
    await WidgetsBinding.instance.endOfFrame;
    try {
      await old.dispose();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _scannerGeneration++;
      _scanner = _newScanner();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pairing.dispose();
    final scanner = _scanner;
    _scanner = null;
    super.dispose();
    // After super.dispose() the MobileScanner widget has detached (its own
    // dispose already stopped the camera); finish tearing down.
    if (scanner != null) unawaited(scanner.dispose());
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
      // Switching stages unmounts MobileScanner, which stops the camera
      // itself; this just cuts the feed within the same frame.
      unawaited(_scanner?.stop().catchError((_) {}));
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
    // Re-entering the scanning stage remounts MobileScanner, whose autoStart
    // restarts the camera — no manual start call.
    _pairing.scanAgain();
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
            onPressed: () => _scanner?.toggleTorch(),
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
    final scanner = _scanner;
    return Stack(
      alignment: Alignment.center,
      children: [
        if (scanner == null)
          // Mid cold-restart (old session tearing down); one frame of spinner.
          const ColoredBox(
            color: Colors.black,
            child: Center(child: CircularProgressIndicator()),
          )
        else
          MobileScanner(
            // The generation key ties this widget to exactly one controller:
            // a cold restart swaps both together (never rebinds a live view).
            key: ValueKey(_scannerGeneration),
            controller: scanner,
            onDetect: _onDetect,
            placeholderBuilder: (context) => const ColoredBox(
              color: Colors.black,
              child: Center(child: CircularProgressIndicator()),
            ),
            errorBuilder: (context, error) =>
                _CameraError(error: error, onRetry: _remountScanner),
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
    final scheme = Theme.of(context).colorScheme;
    final details = error.errorDetails?.message;
    final diagnostic = [
      error.errorCode.name,
      if (details != null && details.isNotEmpty) details,
    ].join(' — ');
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
            const SizedBox(height: 8),
            // The raw plugin error (English), so failures are reportable.
            Text(
              diagnostic,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontFamily: 'monospace',
              ),
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
