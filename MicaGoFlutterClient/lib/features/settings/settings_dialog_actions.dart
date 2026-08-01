import 'package:flutter/material.dart';

/// Consistent two-button action row for Settings confirmation dialogs.
class SettingsDialogActionRow extends StatelessWidget {
  const SettingsDialogActionRow({
    super.key,
    required this.cancelLabel,
    required this.onCancel,
    required this.confirmLabel,
    required this.onConfirm,
    this.destructive = false,
  });

  final String cancelLabel;
  final VoidCallback onCancel;
  final String confirmLabel;
  final VoidCallback onConfirm;

  /// C76: paints the confirm button in the error colour for actions that
  /// destroy local data (unpairing wipes the token and the message cache).
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.maxFinite,
      height: 48,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: onCancel,
              child: Text(cancelLabel),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton(
              onPressed: onConfirm,
              style: destructive
                  ? FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                      foregroundColor: Theme.of(context).colorScheme.onError,
                    )
                  : null,
              child: Text(confirmLabel),
            ),
          ),
        ],
      ),
    );
  }
}
