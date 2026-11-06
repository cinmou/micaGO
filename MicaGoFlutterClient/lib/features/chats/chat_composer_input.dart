import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ChatComposerInput extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final Color textColor;
  final Color hintColor;
  final Color cursorColor;
  final String hint;
  final ValueChanged<KeyboardInsertedContent> onContentInserted;
  final VoidCallback? onSend;
  final Future<bool> Function()? onPasteAttachments;

  const ChatComposerInput({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.textColor,
    required this.hintColor,
    required this.cursorColor,
    required this.hint,
    required this.onContentInserted,
    this.onSend,
    this.onPasteAttachments,
  });

  @override
  Widget build(BuildContext context) {
    final input = TextField(
      controller: controller,
      focusNode: focusNode,
      minLines: 1,
      maxLines: 5,
      style: TextStyle(color: textColor, fontSize: 16, height: 1.3),
      strutStyle: const StrutStyle(fontSize: 16, height: 1.3),
      cursorColor: cursorColor,
      textAlignVertical: TextAlignVertical.center,
      textInputAction: TextInputAction.newline,
      keyboardType: TextInputType.multiline,
      contentInsertionConfiguration: ContentInsertionConfiguration(
        allowedMimeTypes: const [
          'image/png',
          'image/gif',
          'image/jpeg',
          'image/jpg',
          'image/bmp',
          'image/tiff',
          'image/webp',
          'image/heic',
          'image/heif',
        ],
        onContentInserted: onContentInserted,
      ),
      contextMenuBuilder: onPasteAttachments == null
          ? (context, editable) => AdaptiveTextSelectionToolbar.editableText(
              editableTextState: editable,
            )
          : (context, editable) {
              final items = editable.contextMenuButtonItems
                  .where((item) => item.kind != ContextMenuButtonKind.paste)
                  .toList();
              items.insert(
                0,
                ContextMenuButtonItem(
                  kind: ContextMenuButtonKind.paste,
                  onPressed: () async {
                    editable.hideToolbar();
                    final handled = await onPasteAttachments!();
                    if (!handled && editable.mounted) {
                      await editable.pasteText(SelectionChangedCause.toolbar);
                    }
                  },
                ),
              );
              return AdaptiveTextSelectionToolbar.buttonItems(
                anchors: editable.contextMenuAnchors,
                buttonItems: items,
              );
            },
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: hintColor, fontSize: 16, height: 1.3),
        border: InputBorder.none,
        isCollapsed: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
      ),
    );
    final pasteInput = onPasteAttachments == null
        ? input
        : Actions(
            actions: {
              PasteTextIntent: _PasteAttachmentAction(
                onPasteAttachments!,
                () => context.mounted,
              ),
            },
            child: input,
          );
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.linux) {
      return pasteInput;
    }

    return Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) {
        final keyboard = HardwareKeyboard.instance;
        final pasteShortcut =
            onPasteAttachments != null &&
            ((keyboard.isControlPressed &&
                    !keyboard.isShiftPressed &&
                    event.logicalKey == LogicalKeyboardKey.keyV) ||
                (keyboard.isShiftPressed &&
                    !keyboard.isControlPressed &&
                    event.logicalKey == LogicalKeyboardKey.insert));
        if (pasteShortcut &&
            !keyboard.isAltPressed &&
            !keyboard.isMetaPressed &&
            (event is KeyDownEvent || event is KeyRepeatEvent)) {
          if (event is KeyDownEvent) {
            Actions.invoke(
              focusNode.context!,
              const PasteTextIntent(SelectionChangedCause.keyboard),
            );
          }
          return KeyEventResult.handled;
        }
        final enter =
            event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter;
        if (!enter ||
            keyboard.isShiftPressed ||
            keyboard.isAltPressed ||
            keyboard.isMetaPressed ||
            (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
          return KeyEventResult.ignored;
        }
        if (event is KeyDownEvent) {
          if (keyboard.isControlPressed) {
            _insertNewline();
          } else {
            _sendIfReady();
          }
        }
        return KeyEventResult.handled;
      },
      child: pasteInput,
    );
  }

  void _insertNewline() {
    final value = controller.value;
    if (value.composing.isValid && !value.composing.isCollapsed) return;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    controller.value = TextEditingValue(
      text: value.text.replaceRange(start, end, '\n'),
      selection: TextSelection.collapsed(offset: start + 1),
    );
  }

  void _sendIfReady() {
    // Let the input method finish choosing text before submitting a message.
    final composing = controller.value.composing;
    if (composing.isValid && !composing.isCollapsed) return;
    onSend?.call();
  }
}

class _PasteAttachmentAction extends Action<PasteTextIntent> {
  _PasteAttachmentAction(this.pasteAttachments, this.isMounted);

  final Future<bool> Function() pasteAttachments;
  final bool Function() isMounted;

  @override
  Future<void> invoke(PasteTextIntent intent) async {
    final textPaste = callingAction;
    final handled = await pasteAttachments();
    if (!handled && isMounted()) textPaste?.invoke(intent);
  }
}
