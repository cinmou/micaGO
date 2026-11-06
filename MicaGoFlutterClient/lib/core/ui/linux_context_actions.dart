import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform/linux_desktop.dart';

/// Open an item's existing actions with right click or the keyboard menu key.
class LinuxContextActions extends StatelessWidget {
  const LinuxContextActions({
    super.key,
    required this.child,
    required this.onOpen,
  });

  final Widget child;
  final ValueChanged<Offset> onOpen;

  @override
  Widget build(BuildContext context) {
    if (!isLinuxDesktop) return child;
    return Focus(
      onKeyEvent: (_, event) {
        final isMenuKey = event.logicalKey == LogicalKeyboardKey.contextMenu;
        final isMenuShortcut =
            event.logicalKey == LogicalKeyboardKey.f10 &&
            HardwareKeyboard.instance.isShiftPressed;
        if (event is KeyDownEvent && (isMenuKey || isMenuShortcut)) {
          final box = context.findRenderObject() as RenderBox;
          onOpen(box.localToGlobal(Offset(box.size.width - 16, 24)));
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapDown: (details) => onOpen(details.globalPosition),
        child: child,
      ),
    );
  }
}
