import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/ui/app_dialog.dart';
import '../../core/l10n/app_localizations.dart';

Future<bool> confirmCompatibilityStorage(BuildContext context) async {
  if (!context.mounted) return false;
  final strings = MicaLocalizations.of(context);
  return await showAppDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AppDialog(
          title: Text(strings.t('pair.compatibilityTitle')),
          content: Text(strings.t('pair.compatibilityBody')),
          cancelLabel: strings.t('settings.cancel'),
          onCancel: () => Navigator.pop(context, false),
          confirmLabel: strings.t('pair.enableCompatibility'),
          onConfirm: () => Navigator.pop(context, true),
        ),
      ) ??
      false;
}

Future<String?> requestPairingJson(BuildContext context) async {
  final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
  if (!context.mounted) return null;
  final strings = MicaLocalizations.of(context);
  return showAppTextInput(
    context: context,
    title: strings.t('pair.pasteJson'),
    hint: strings.t('pair.pasteJsonHint'),
    initialText: clipboard?.text?.trim() ?? '',
    cancelLabel: strings.t('settings.cancel'),
    confirmLabel: strings.t('pair.connect'),
  );
}
