import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../../core/backup/backup_service.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/theme_controller.dart';
import '../contacts/contacts_service.dart';
import 'message_display_controller.dart';
import 'settings_dialog_actions.dart';

/// Shared "Backup & Restore" flows (C54) used by both Settings and the pairing
/// screen. Export writes an unencrypted `.micagobak` zip (contains the bearer
/// token — warned about); import parses, previews, confirms, applies, then
/// reloads the app state and reconnects.

Future<void> exportSettingsBackup(BuildContext context) async {
  final strings = MicaLocalizations.of(context);
  final app = context.read<AppController>();
  // Warn: the backup carries the server token.
  final proceed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(MicaLocalizations.of(ctx).t('backup.exportTitle')),
      content: Text(MicaLocalizations.of(ctx).t('backup.tokenWarning')),
      actions: [
        SettingsDialogActionRow(
          cancelLabel: MicaLocalizations.of(ctx).t('settings.cancel'),
          onCancel: () => Navigator.pop(ctx, false),
          confirmLabel: MicaLocalizations.of(ctx).t('backup.export'),
          onConfirm: () => Navigator.pop(ctx, true),
        ),
      ],
    ),
  );
  if (proceed != true || !context.mounted) return;

  final service = BackupService(store: app.store, cache: app.cache);
  try {
    final bytes = await service.exportBackup();
    if (!context.mounted) return;
    final path = await FilePicker.platform.saveFile(
      dialogTitle: strings.t('backup.export'),
      fileName: service.suggestedFileName(),
      bytes: bytes,
    );
    if (!context.mounted) return;
    _toast(
      context,
      path == null
          ? strings.t('backup.exportCancelled')
          : strings.t('backup.exportDone'),
    );
  } catch (e) {
    if (context.mounted) {
      _toast(context, '${strings.t('backup.exportFailed')}: $e');
    }
  }
}

/// Returns true when a backup was successfully restored.
Future<bool> importSettingsBackup(BuildContext context) async {
  final strings = MicaLocalizations.of(context);
  final app = context.read<AppController>();
  final service = BackupService(store: app.store, cache: app.cache);

  final picked = await FilePicker.platform.pickFiles(
    dialogTitle: strings.t('backup.import'),
    type: FileType.any,
    withData: true,
  );
  final data = picked?.files.firstOrNull?.bytes;
  if (data == null || !context.mounted) return false;

  BackupSummary summary;
  try {
    summary = BackupService.inspect(data);
  } on BackupException catch (e) {
    if (context.mounted) _toast(context, e.message);
    return false;
  } catch (_) {
    if (context.mounted) {
      _toast(context, strings.t('backup.importInvalid'));
    }
    return false;
  }

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final s = MicaLocalizations.of(ctx);
      final items = <String>[
        if (summary.hasServer) s.t('backup.itemServer'),
        if (summary.hasAppearance) s.t('backup.itemAppearance'),
        if (summary.hasChatBackground) s.t('backup.itemChatBackground'),
        if (summary.hasMessageDisplay) s.t('backup.itemMessageDisplay'),
        if (summary.customAvatarCount > 0)
          '${s.t('backup.itemAvatars')} (${summary.customAvatarCount})',
        if (summary.pinnedHiddenCount > 0)
          '${s.t('backup.itemPinHide')} (${summary.pinnedHiddenCount})',
        if (summary.hiddenMessageCount > 0)
          '${s.t('backup.itemHiddenMessages')} (${summary.hiddenMessageCount})',
      ];
      return AlertDialog(
        title: Text(s.t('backup.restoreTitle')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.t('backup.restoreSummary')),
            const SizedBox(height: 8),
            for (final item in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text('• $item'),
              ),
            const SizedBox(height: 12),
            Text(
              s.t('backup.restoreReplaceWarning'),
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ],
        ),
        actions: [
          SettingsDialogActionRow(
            cancelLabel: s.t('settings.cancel'),
            onCancel: () => Navigator.pop(ctx, false),
            confirmLabel: s.t('backup.restore'),
            onConfirm: () => Navigator.pop(ctx, true),
          ),
        ],
      );
    },
  );
  if (confirmed != true || !context.mounted) return false;

  // Capture the controllers before the async gap.
  final themeController = context.read<ThemeController>();
  final messageDisplay = context.read<MessageDisplayController>();
  final contacts = context.read<ContactsService>();
  try {
    await service.applyBackup(data);
    // Rebuild the storage-backed controllers + reconnect.
    await themeController.bootstrap();
    await messageDisplay.bootstrap();
    await contacts.bootstrap();
    await app.reloadAfterRestore();
    if (context.mounted) _toast(context, strings.t('backup.restoreDone'));
    return true;
  } catch (e) {
    if (context.mounted) {
      _toast(context, '${strings.t('backup.restoreFailed')}: $e');
    }
    return false;
  }
}

void _toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(message)));
}
