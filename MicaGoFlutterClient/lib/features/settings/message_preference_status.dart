import 'package:flutter/material.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/network/message_preference_sync.dart';
import '../../core/ui/top_banner.dart';

class MessagePreferenceStatus extends StatelessWidget {
  final MessagePreferenceSync preferences;

  /// Without the description the widget renders nothing unless there is
  /// something to act on: a sync error, conflicts, legacy records, or pending
  /// changes.
  final bool showDescription;
  final EdgeInsetsGeometry padding;

  const MessagePreferenceStatus({
    super.key,
    required this.preferences,
    this.showDescription = false,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: preferences,
    builder: (context, _) {
      final strings = MicaLocalizations.of(context);
      final theme = Theme.of(context);
      final needsAttention =
          preferences.errorKey != null ||
          preferences.legacyCount > 0 ||
          preferences.hasConflicts ||
          preferences.pending;
      if (!showDescription && !needsAttention) {
        return const SizedBox.shrink();
      }

      Future<void> run(Future<void> Function() action) async {
        try {
          await action();
        } catch (_) {
          if (context.mounted) {
            TopBanner.show(
              context,
              strings.t('prefs.connect'),
              kind: TopBannerKind.error,
            );
          }
        }
      }

      return Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showDescription)
              Text(
                strings.t('prefs.description'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            if (preferences.errorKey != null)
              Text(
                strings.t(preferences.errorKey!),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            if (preferences.legacyCount > 0)
              TextButton(
                onPressed: () => run(preferences.importLegacy),
                child: Text(
                  strings
                      .t('prefs.import')
                      .replaceAll('{n}', '${preferences.legacyCount}'),
                ),
              ),
            if (preferences.hasConflicts)
              Wrap(
                children: [
                  TextButton(
                    onPressed: () => run(preferences.acceptServer),
                    child: Text(strings.t('prefs.server')),
                  ),
                  TextButton(
                    onPressed: () => run(preferences.retryConflicts),
                    child: Text(strings.t('prefs.retryMine')),
                  ),
                ],
              ),
            if (preferences.pending || preferences.errorKey != null)
              TextButton(
                onPressed: () => run(preferences.sync),
                child: Text(strings.t('prefs.retry')),
              ),
          ],
        ),
      );
    },
  );
}
