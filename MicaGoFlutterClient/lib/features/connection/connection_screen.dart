import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/router.dart';
import '../settings/backup_restore_ui.dart';
import '../../core/app_controller.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/models/connection_profile.dart';
import '../../core/network/endpoint_utils.dart';
import '../../core/network/manual_connection_profile.dart';
import '../pairing/pairing_payload.dart';
import 'connection_controller.dart';

/// Connection setup. Normal paths are QR scan and pasted v3 connection JSON.
/// Low-level URL entry is kept only as an advanced fallback and still generates
/// the same LAN/Public candidate model used by QR pairing.
class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  final _formKey = GlobalKey<FormState>();
  final _publicUrlCtrl = TextEditingController();
  final _lanUrlCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();
  bool _obscureToken = true;
  String? _pasteError;

  late final ConnectionController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ConnectionController(context.read<AppController>());
    final existing = _controller.app.profile;
    if (existing != null) {
      _publicUrlCtrl.text = existing.publicBaseUrl ?? '';
      _lanUrlCtrl.text = existing.lanBaseUrl ?? '';
      _tokenCtrl.text = existing.token;
      if (_publicUrlCtrl.text.isEmpty && _lanUrlCtrl.text.isEmpty) {
        _publicUrlCtrl.text = existing.baseUrl;
      }
    }
    _publicUrlCtrl.addListener(() => setState(() {}));
    _lanUrlCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    _publicUrlCtrl.dispose();
    _lanUrlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  ConnectionProfile _buildAdvancedProfile() {
    return advancedManualProfile(
      publicBaseUrl: _publicUrlCtrl.text,
      lanBaseUrl: _lanUrlCtrl.text,
      token: _tokenCtrl.text,
    );
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
      await _controller.save(profile);
      if (!mounted) return;
      context.go(Routes.home);
    } on PairingParseException catch (e) {
      setState(() => _pasteError = e.message);
    }
  }

  Future<void> _onTestAdvanced() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    await _controller.test(_buildAdvancedProfile());
  }

  Future<void> _onSaveAdvanced() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    await _controller.save(_buildAdvancedProfile());
    if (!mounted) return;
    context.go(Routes.home);
  }

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(strings.t('pair.connectToMicaGo'))),
      body: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: _controller,
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
                  // C54: restore a settings backup (server + token + prefs) to get
                  // straight back in after a reinstall / new device.
                  OutlinedButton.icon(
                    onPressed: () async {
                      final ok = await importSettingsBackup(context);
                      if (ok && context.mounted) context.go(Routes.home);
                    },
                    icon: const Icon(Icons.restore),
                    label: Text(strings.t('settings.importBackup')),
                  ),
                  if (_pasteError != null) ...[
                    const SizedBox(height: 12),
                    _InlineError(text: _pasteError!),
                  ],
                  const SizedBox(height: 24),
                  Form(
                    key: _formKey,
                    child: ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: Text(strings.t('pair.advancedSetup')),
                      subtitle: Text(strings.t('pair.advancedSetupHint')),
                      children: [
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _publicUrlCtrl,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          decoration: InputDecoration(
                            labelText: strings.t('pair.publicUrl'),
                            hintText: 'https://mica.example.com',
                            helperText: _derivedPublicWs,
                            prefixIcon: const Icon(Icons.public_outlined),
                          ),
                          validator: (v) => _optionalUrlValidator(v, 'Public'),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _lanUrlCtrl,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          decoration: InputDecoration(
                            labelText: strings.t('pair.lanUrl'),
                            hintText: 'http://192.168.1.23:3000',
                            helperText: _derivedLanWs,
                            prefixIcon: const Icon(Icons.wifi_tethering),
                          ),
                          validator: (v) => _optionalUrlValidator(v, 'LAN'),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _tokenCtrl,
                          obscureText: _obscureToken,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: InputDecoration(
                            labelText: strings.t('pair.bearerToken'),
                            prefixIcon: const Icon(Icons.key_outlined),
                            suffixIcon: IconButton(
                              tooltip: _obscureToken ? 'Show' : 'Hide',
                              icon: Icon(
                                _obscureToken
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                              onPressed: () => setState(
                                () => _obscureToken = !_obscureToken,
                              ),
                            ),
                          ),
                          validator: (v) => (v ?? '').trim().isEmpty
                              ? 'Token is required'
                              : null,
                        ),
                        const SizedBox(height: 20),
                        OutlinedButton.icon(
                          onPressed: _controller.state == TestState.testing
                              ? null
                              : _onTestAdvanced,
                          icon: _controller.state == TestState.testing
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.wifi_tethering),
                          label: Text(strings.t('pair.testAdvanced')),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _onSaveAdvanced,
                          icon: const Icon(Icons.save_outlined),
                          label: Text(strings.t('pair.saveAdvanced')),
                        ),
                        const SizedBox(height: 16),
                        _TestResult(controller: _controller),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  String? get _derivedPublicWs {
    final raw = _publicUrlCtrl.text.trim();
    if (raw.isEmpty) return null;
    return 'WebSocket: ${deriveWebSocketUrl(raw)}';
  }

  String? get _derivedLanWs {
    final raw = _lanUrlCtrl.text.trim();
    if (raw.isEmpty) return null;
    return 'WebSocket: ${deriveWebSocketUrl(raw)}';
  }

  String? _optionalUrlValidator(String? value, String label) {
    final raw = value?.trim() ?? '';
    final other = label == 'Public' ? _lanUrlCtrl.text : _publicUrlCtrl.text;
    if (raw.isEmpty) {
      if (other.trim().isEmpty) {
        return 'Enter a Public URL, a LAN URL, or paste connection JSON.';
      }
      return null;
    }
    return isValidHttpUrl(raw) ? null : 'Enter a valid http(s) origin';
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

class _TestResult extends StatelessWidget {
  final ConnectionController controller;
  const _TestResult({required this.controller});

  @override
  Widget build(BuildContext context) {
    if (controller.state == TestState.idle ||
        controller.state == TestState.testing) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    final ok = controller.state == TestState.success;
    final color = ok ? scheme.primary : scheme.error;
    return Card(
      color: (ok ? scheme.primaryContainer : scheme.errorContainer).withValues(
        alpha: 0.4,
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              ok ? Icons.check_circle_outline : Icons.error_outline,
              color: color,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(controller.message ?? '')),
          ],
        ),
      ),
    );
  }
}
