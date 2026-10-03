import '../../core/ui/app_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'message_render.dart';
import 'models/message_model.dart';
import '../../core/l10n/app_localizations.dart';

/// Message info sheet with a redacted diagnostic payload. Never shows the
/// bearer token or credentials (see [messageDebugMap] / [redactJson]).
Future<void> showMessageDebugSheet(BuildContext context, MessageModel m) {
  return showAppBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _MessageDebugSheet(message: m),
  );
}

class _MessageDebugSheet extends StatelessWidget {
  final MessageModel message;
  const _MessageDebugSheet({required this.message});

  @override
  Widget build(BuildContext context) {
    final map = messageDebugMap(message);
    final json = messageDebugJson(message);
    final cls = classifyMessage(message);
    final scheme = Theme.of(context).colorScheme;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, controller) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: ListView(
          controller: controller,
          children: [
            Row(
              children: [
                const Icon(Icons.info_outline),
                const SizedBox(width: 8),
                Text(
                  MicaLocalizations.of(context).t('chat.messageInfo'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                FilledButton.tonalIcon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: json));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          MicaLocalizations.of(
                            context,
                          ).t('chat.debugJsonCopied'),
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: Text(
                    MicaLocalizations.of(context).t('chat.copyDebugJson'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Chip(
              label: Text(
                '${cls.kind.name} · ${unsupportedReasonLabel(cls.reason)}',
              ),
              side: BorderSide(
                color: cls.isUnsupported ? scheme.error : scheme.outline,
              ),
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(height: 8),
            for (final entry in map.entries)
              if (entry.key != 'raw') _kv(context, entry.key, entry.value),
            const Divider(height: 24),
            Text(
              'Raw payload (redacted)',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                prettyJson(map['raw']),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _kv(BuildContext context, String k, Object? v) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              k,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: SelectableText(
              '${v ?? '—'}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
