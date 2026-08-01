import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/l10n/app_localizations.dart';
import '../chats/message_display.dart';
import 'message_display_controller.dart';

/// Settings → "Message display" (Part I). Local display preferences only — they
/// never delete or change server data, and never hide failed outgoing messages.
///
/// C75: the "Debug details for unsupported messages" section was removed — the
/// `unsupportedDetails` preference it wrote had no consumer anywhere in the app,
/// so all three choices did nothing. Everything left is localized.
class MessageDisplayPage extends StatelessWidget {
  const MessageDisplayPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<MessageDisplayController>();
    final strings = MicaLocalizations.of(context);
    final p = controller.prefs;
    void set(MessageDisplayPrefs next) => controller.update(next);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          strings.t('display.note'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              SwitchListTile(
                title: Text(strings.t('display.hideUnsupported')),
                subtitle: Text(strings.t('display.hideUnsupportedBody')),
                value: p.hideUnsupportedRows,
                onChanged: (v) => set(p.copyWith(hideUnsupportedRows: v)),
              ),
              const Divider(height: 1),
              SwitchListTile(
                title: Text(strings.t('display.mergeSystem')),
                value: p.mergeConsecutiveSystem,
                onChanged: (v) => set(p.copyWith(mergeConsecutiveSystem: v)),
              ),
              const Divider(height: 1),
              SwitchListTile(
                title: Text(strings.t('display.mergeTapbacks')),
                subtitle: Text(strings.t('display.mergeTapbacksBody')),
                value: p.mergeTapbacks,
                onChanged: (v) => set(p.copyWith(mergeTapbacks: v)),
              ),
              const Divider(height: 1),
              SwitchListTile(
                title: Text(strings.t('display.effectHints')),
                subtitle: Text(strings.t('display.effectHintsBody')),
                value: p.showEffectHints,
                onChanged: (v) => set(p.copyWith(showEffectHints: v)),
              ),
              const Divider(height: 1),
              SwitchListTile(
                title: Text(strings.t('display.debugChats')),
                subtitle: Text(strings.t('display.debugChatsBody')),
                value: p.showDebugChats,
                onChanged: (v) => set(p.copyWith(showDebugChats: v)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(
          strings.t('display.deliveryLabels'),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              for (final mode in DeliveryLabelMode.values)
                _ChoiceTile(
                  label: strings.t(_deliveryLabelKey(mode)),
                  selected: p.deliveryLabels == mode,
                  onTap: () => set(p.copyWith(deliveryLabels: mode)),
                ),
            ],
          ),
        ),
      ],
    );
  }

  String _deliveryLabelKey(DeliveryLabelMode m) => switch (m) {
    DeliveryLabelMode.off => 'display.deliveryOff',
    DeliveryLabelMode.compact => 'display.deliveryCompact',
    DeliveryLabelMode.detailed => 'display.deliveryDetailed',
  };
}

/// A single-select list row (avoids the deprecated RadioListTile API).
class _ChoiceTile extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ChoiceTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      title: Text(label),
      onTap: onTap,
      trailing: selected
          ? Icon(Icons.check, color: scheme.primary)
          : const SizedBox(width: 24),
    );
  }
}
