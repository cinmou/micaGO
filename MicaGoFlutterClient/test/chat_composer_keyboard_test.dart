import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/features/chats/chat_composer_input.dart';

void main() {
  late TextEditingController controller;
  late FocusNode focus;
  late int sends;

  setUp(() {
    controller = TextEditingController(text: 'Hello');
    focus = FocusNode();
    sends = 0;
  });

  tearDown(() {
    controller.dispose();
    focus.dispose();
  });

  Future<void> mount(
    WidgetTester tester, {
    bool canSend = true,
    Future<bool> Function()? onPasteAttachments,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposerInput(
            controller: controller,
            focusNode: focus,
            textColor: Colors.black,
            hintColor: Colors.grey,
            cursorColor: Colors.blue,
            hint: 'Message',
            onContentInserted: (_) {},
            onSend: canSend ? () => sends++ : null,
            onPasteAttachments: onPasteAttachments,
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
  }

  Future<void> sendShortcut(
    WidgetTester tester, {
    LogicalKeyboardKey key = LogicalKeyboardKey.enter,
  }) => tester.sendKeyEvent(key);

  testWidgets('attachment paste handles Ctrl+V without inserting file text', (
    tester,
  ) async {
    var pastes = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async =>
          call.method == 'Clipboard.hasStrings' ? {'value': false} : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await mount(
      tester,
      onPasteAttachments: () async {
        pastes++;
        return true;
      },
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(pastes, 1);
    expect(controller.text, 'Hello');
    expect(sends, 0);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.insert);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(pastes, 2);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('plain text paste uses the original selection replacement', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => switch (call.method) {
        'Clipboard.getData' => {'text': 'world'},
        'Clipboard.hasStrings' => {'value': true},
        _ => null,
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await mount(tester, onPasteAttachments: () async => false);
    controller.selection = const TextSelection(baseOffset: 1, extentOffset: 4);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(controller.text, 'Hworldo');
    expect(controller.selection.baseOffset, 6);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('image-only clipboard still offers paste in the input menu', (
    tester,
  ) async {
    var pastes = 0;
    await mount(
      tester,
      onPasteAttachments: () async {
        pastes++;
        return true;
      },
    );
    final editable = tester.state<EditableTextState>(find.byType(EditableText));
    editable.renderEditable.selectPositionAt(
      from: tester.getCenter(find.byType(TextField)),
      cause: SelectionChangedCause.toolbar,
    );
    editable.showToolbar();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste'));
    await tester.pumpAndSettle();
    expect(pastes, 1);
    expect(controller.text, 'Hello');
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('Linux sends with Enter and keypad Enter', (tester) async {
    await mount(tester);
    await sendShortcut(tester);
    await sendShortcut(tester, key: LogicalKeyboardKey.numpadEnter);
    expect(sends, 2);
    expect(focus.hasFocus, isTrue);
    expect(controller.text, 'Hello');
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('Linux does not send while the input method is composing', (
    tester,
  ) async {
    await mount(tester);
    controller.value = const TextEditingValue(
      text: 'ni',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    );
    await sendShortcut(tester);
    expect(sends, 0);
    controller.value = const TextEditingValue(
      text: '你',
      selection: TextSelection.collapsed(offset: 1),
    );
    await sendShortcut(tester);
    expect(sends, 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('Linux respects disabled sending', (tester) async {
    await mount(tester, canSend: false);
    await sendShortcut(tester);
    expect(sends, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('Linux does not resend on key repeat', (tester) async {
    await mount(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    expect(sends, 1);
    expect(controller.text, 'Hello');
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('Ctrl+Enter replaces the selection with a newline', (
    tester,
  ) async {
    await mount(tester);
    controller.selection = const TextSelection(baseOffset: 1, extentOffset: 4);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(sends, 0);
    expect(controller.text, 'H\no');
    expect(controller.selection, const TextSelection.collapsed(offset: 2));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(controller.text, 'H\n\no');
    expect(focus.hasFocus, isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('Shift+Enter does not submit', (tester) async {
    await mount(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(sends, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('Android keeps its existing input behavior', (tester) async {
    await mount(tester);
    await sendShortcut(tester);
    expect(sends, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
