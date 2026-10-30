import 'package:flutter/material.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/network/hidden_preference_sync.dart';
import '../../core/network/api_client.dart';
import '../../core/ui/top_banner.dart';

class HiddenPreferenceStatus extends StatelessWidget {
  final HiddenPreferenceSync preferences;

  final EdgeInsetsGeometry padding;

  const HiddenPreferenceStatus({
    super.key,
    required this.preferences,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: preferences,
    builder: (context, _) {
      final strings = MicaLocalizations.of(context);
      final needsAttention =
          preferences.errorKey != null ||
          preferences.legacyCount > 0 ||
          preferences.hasConflicts ||
          preferences.pending;
      if (!needsAttention) {
        return const SizedBox.shrink();
      }

      Future<void> run(Future<void> Function() action) async {
        try {
          await action();
        } catch (error) {
          if (context.mounted) {
            TopBanner.show(
              context,
              error is ApiException
                  ? error.localizedMessage()
                  : strings.t('prefs.failed'),
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
            if (preferences.errorKey != null)
              Text(
                preferences.errorMessage ?? strings.t(preferences.errorKey!),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
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
