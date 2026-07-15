import 'package:flutter/material.dart';

bool _hasEditableFocus() {
  final focus = FocusManager.instance.primaryFocus;
  if (focus == null || !focus.hasFocus) return false;
  final context = focus.context;
  if (context == null) return true;
  return context.widget is EditableText ||
      context.findAncestorWidgetOfExactType<EditableText>() != null;
}

double activeKeyboardInset(BuildContext context, {bool enabled = true}) {
  if (!enabled || !_hasEditableFocus()) return 0;
  return MediaQuery.viewInsetsOf(context).bottom;
}

MediaQueryData withoutStaleKeyboardInset(BuildContext context) {
  final data = MediaQuery.of(context);
  if (data.viewInsets.bottom == 0 || _hasEditableFocus()) return data;
  final insets = data.viewInsets;
  return data.copyWith(
    viewInsets: EdgeInsets.fromLTRB(insets.left, insets.top, insets.right, 0),
  );
}

class KeyboardInsetGuard extends StatelessWidget {
  final Widget child;

  const KeyboardInsetGuard({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return MediaQuery(data: withoutStaleKeyboardInset(context), child: child);
  }
}
