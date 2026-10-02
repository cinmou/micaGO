import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/router.dart';
import '../settings/backup_restore_ui.dart';
import '../../core/app_controller.dart';
import '../../core/l10n/app_localizations.dart';
import '../pairing/pairing_payload.dart';

/// Connection setup through QR or the same pasted single-use invitation.
class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  String? _pasteError;

  late final AppController _app;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppController>();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _pasteConnectionJson() async {
    setState(() => _pasteError = null);
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final controller = TextEditingController(text: clip?.text?.trim() ?? '');
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(MicaLocalizations.of(ctx).t('pair.pasteJson')),
        content: TextField(
          controller: controller,
          maxLines: 7,
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
    if (raw == null || raw.isEmpty) return;
    try {
      final profile = parsePairingPayload(raw).toProfile();
      if (profile.pairingCode == null) {
        throw PairingParseException(
          MicaLocalizations.current.t('pair.secureUpgrade'),
        );
      }
      await _app.saveAndActivate(profile);
      if (!mounted) return;
      context.go(Routes.home);
    } on PairingParseException catch (e) {
      setState(() => _pasteError = e.message);
    } catch (error) {
      if (mounted) setState(() => _pasteError = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(strings.t('pair.connectToMicaGo'))),
      body: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: _app,
          builder: (context, _) {
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                16 + MediaQuery.paddingOf(context).bottom,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _BrandHeader(strings: strings),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: () => context.push(Routes.pair),
                    icon: const Icon(Icons.qr_code_scanner),
                    label: Text(strings.t('pair.scanQr')),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: _pasteConnectionJson,
                    icon: const Icon(Icons.content_paste),
                    label: Text(strings.t('pair.pasteJson')),
                  ),
                  const SizedBox(height: 12),
                  // Settings restore preserves this install's device credentials.
                  OutlinedButton.icon(
                    onPressed: () async {
                      final ok = await importSettingsBackup(context);
                      if (ok && context.mounted && _app.profile != null) {
                        context.go(Routes.home);
                      }
                    },
                    icon: const Icon(Icons.restore),
                    label: Text(strings.t('settings.importBackup')),
                  ),
                  if (_pasteError != null) ...[
                    const SizedBox(height: 12),
                    _InlineError(text: _pasteError!),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _BrandHeader extends StatelessWidget {
  final MicaLocalizations strings;
  const _BrandHeader({required this.strings});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(Icons.bolt, color: scheme.onPrimaryContainer),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('micaGO', style: Theme.of(context).textTheme.headlineSmall),
            Text(
              strings.t('pair.headerSubtitle'),
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ],
    );
  }
}

class _InlineError extends StatelessWidget {
  final String text;
  const _InlineError({required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: scheme.error),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
