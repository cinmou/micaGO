import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/l10n/app_localizations.dart';
import '../../core/ui/top_banner.dart';

enum LauncherIconChoice { defaultIcon, classic, minimal }

extension LauncherIconChoiceInfo on LauncherIconChoice {
  String get id => this == LauncherIconChoice.defaultIcon ? 'default' : name;
  String get preview => 'lib/Assets/launcher_icons/$id.png';
}

class LauncherIconPicker extends StatefulWidget {
  const LauncherIconPicker({super.key});

  @override
  State<LauncherIconPicker> createState() => _LauncherIconPickerState();
}

class _LauncherIconPickerState extends State<LauncherIconPicker>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('micago/launcher_icons');
  LauncherIconChoice? _selected;
  bool _busy = false;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_busy) _load();
  }

  LauncherIconChoice _parse(String? id) =>
      LauncherIconChoice.values.firstWhere((choice) => choice.id == id);

  Future<void> _load() async {
    try {
      final id = await _channel.invokeMethod<String>('current');
      if (!mounted) return;
      setState(() {
        _selected = _parse(id);
        _loadFailed = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  Future<void> _select(LauncherIconChoice choice) async {
    if (_busy || choice == _selected) return;
    setState(() => _busy = true);
    try {
      final id = await _channel.invokeMethod<String>('select', {
        'icon': choice.id,
      });
      if (!mounted) return;
      setState(() => _selected = _parse(id));
      TopBanner.show(
        context,
        MicaLocalizations.of(context).t('settings.iconChanged'),
      );
    } catch (_) {
      await _load();
      if (!mounted) return;
      TopBanner.show(
        context,
        MicaLocalizations.of(context).t('settings.iconFailed'),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          strings.t('settings.appIcon'),
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 12),
        Row(
          spacing: 8,
          children: [
            for (final choice in LauncherIconChoice.values)
              Expanded(
                child: Semantics(
                  selected: _selected == choice,
                  child: OutlinedButton(
                    onPressed: _busy || _selected == null || _loadFailed
                        ? null
                        : () => _select(choice),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 12,
                      ),
                      backgroundColor: _selected == choice
                          ? scheme.secondaryContainer
                          : null,
                      side: BorderSide(
                        color: _selected == choice
                            ? scheme.primary
                            : scheme.outlineVariant,
                        width: _selected == choice ? 2 : 1,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ClipOval(
                          child: Image.asset(
                            choice.preview,
                            width: 64,
                            height: 64,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(strings.t('settings.icon.${choice.id}')),
                        const SizedBox(height: 4),
                        Icon(
                          _selected == choice
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          size: 18,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (_selected == null && !_loadFailed) const LinearProgressIndicator(),
        if (_loadFailed)
          TextButton(
            onPressed: _busy ? null : _load,
            child: Text(strings.t('settings.iconRetry')),
          ),
        Text(
          strings.t('settings.iconHint'),
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
