import 'package:flutter/material.dart';

/// Shared Material dialog surface for confirmation, notices and input.
class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    required this.title,
    required this.content,
    required this.confirmLabel,
    required this.onConfirm,
    this.cancelLabel,
    this.onCancel,
    this.icon,
    this.destructive = false,
  });
  final Widget title;
  final Widget content;
  final Widget? icon;
  final String confirmLabel;
  final VoidCallback onConfirm;
  final String? cancelLabel;
  final VoidCallback? onCancel;
  final bool destructive;

  @override
  Widget build(BuildContext context) => AlertDialog(
    constraints: const BoxConstraints(maxWidth: 480),
    scrollable: true,
    icon: icon == null
        ? null
        : Align(alignment: AlignmentDirectional.centerStart, child: icon),
    title: Align(alignment: AlignmentDirectional.centerStart, child: title),
    content: content,
    contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
    actionsPadding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
    actions: [
      AppDialogActions(
        confirmLabel: confirmLabel,
        onConfirm: onConfirm,
        cancelLabel: cancelLabel,
        onCancel: onCancel,
        destructive: destructive,
      ),
    ],
  );
}

/// The secondary action precedes the primary action; destructive actions use
/// the theme's error color. Long labels and accessibility text can wrap.
class AppDialogActions extends StatelessWidget {
  const AppDialogActions({
    super.key,
    required this.confirmLabel,
    required this.onConfirm,
    this.cancelLabel,
    this.onCancel,
    this.destructive = false,
  });
  final String confirmLabel;
  final VoidCallback onConfirm;
  final String? cancelLabel;
  final VoidCallback? onCancel;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final primary = FilledButton(
      onPressed: onConfirm,
      style: destructive
          ? FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            )
          : FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      child: Text(confirmLabel, textAlign: TextAlign.center),
    );
    final secondary = cancelLabel == null
        ? null
        : OutlinedButton(
            onPressed: onCancel,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            child: Text(cancelLabel!, textAlign: TextAlign.center),
          );
    if (secondary == null) {
      return SizedBox(width: double.maxFinite, child: primary);
    }
    final narrow = MediaQuery.sizeOf(context).width < 360;
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 20;
    return SizedBox(
      width: double.maxFinite,
      child: narrow || largeText
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [secondary, const SizedBox(height: 8), primary],
            )
          : IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: secondary),
                  const SizedBox(width: 8),
                  Expanded(child: primary),
                ],
              ),
            ),
    );
  }
}

Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) => showDialog<T>(
  context: context,
  builder: builder,
  barrierDismissible: barrierDismissible,
);

Future<T?> showAppBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
}) => showModalBottomSheet<T>(
  context: context,
  builder: builder,
  isScrollControlled: isScrollControlled,
  useSafeArea: true,
  showDragHandle: true,
);

Future<String?> showAppTextInput({
  required BuildContext context,
  required String title,
  required String confirmLabel,
  required String cancelLabel,
  String initialText = '',
  String? hint,
  int maxLines = 6,
}) => showAppDialog<String>(
  context: context,
  builder: (context) => _TextInputDialog(
    title: title,
    confirmLabel: confirmLabel,
    cancelLabel: cancelLabel,
    initialText: initialText,
    hint: hint,
    maxLines: maxLines,
  ),
);

class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog({
    required this.title,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.initialText,
    required this.hint,
    required this.maxLines,
  });
  final String title, confirmLabel, cancelLabel, initialText;
  final String? hint;
  final int maxLines;
  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final controller = TextEditingController(text: widget.initialText);
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: Text(widget.title),
    content: TextField(
      controller: controller,
      autofocus: true,
      minLines: 1,
      maxLines: widget.maxLines,
      decoration: InputDecoration(hintText: widget.hint),
    ),
    cancelLabel: widget.cancelLabel,
    onCancel: () => Navigator.pop(context),
    confirmLabel: widget.confirmLabel,
    onConfirm: () => Navigator.pop(context, controller.text.trim()),
  );
}
