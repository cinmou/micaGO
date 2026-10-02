import 'dart:io';
import 'dart:ui' show ImageByteFormat;
import 'package:flutter/rendering.dart';
import 'package:mica_go/app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/ui/app_dialog.dart';

void main() {
  testWidgets('shared dialog buttons have matching heights', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AppDialogActions(
              cancelLabel: 'Cancel',
              onCancel: () {},
              confirmLabel: 'Confirm',
              onConfirm: () {},
            ),
          ),
        ),
      ),
    );

    final outlined = tester.getSize(find.byType(OutlinedButton));
    final filled = tester.getSize(find.byType(FilledButton));
    expect(outlined.height, 48);
    expect(filled.height, outlined.height);
  });
  testWidgets('long notice scrolls above the keyboard at large text size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final capture = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          theme: MicaGoTheme.fromScheme(
            ColorScheme.fromSeed(seedColor: Colors.blue),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAppDialog<bool>(
                  context: context,
                  builder: (context) => AppDialog(
                    title: const Text('启用兼容存储？'),
                    content: const Text(
                      '系统凭据存储不可用。兼容模式将凭据加密保存在应用私有目录，密钥也保存在本机。获得 root 权限的应用可读取凭据。请仅在可信设备上启用。',
                    ),
                    cancelLabel: '取消',
                    onCancel: () => Navigator.pop(context, false),
                    confirmLabel: '启用兼容模式',
                    onConfirm: () => Navigator.pop(context, true),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.getBottomRight(find.byType(FilledButton)).dy,
      lessThanOrEqualTo(400),
    );
    expect(
      tester.getCenter(find.byType(OutlinedButton)).dy,
      lessThan(tester.getCenter(find.byType(FilledButton)).dy),
    );
    await _preview(tester, capture, 'dialog-narrow.png');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(AppDialog), findsNothing);
  });

  testWidgets('text input can cancel and reopen through the route animation', (
    tester,
  ) async {
    String? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                saved = await showAppTextInput(
                  context: context,
                  title: 'Edit',
                  initialText: 'original',
                  confirmLabel: 'Save',
                  cancelLabel: 'Cancel',
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(saved, isNull);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  updated  ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved, 'updated');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'single notice and destructive confirmation share light and dark surfaces',
    (tester) async {
      for (final brightness in Brightness.values) {
        final capture = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              theme: MicaGoTheme.fromScheme(
                ColorScheme.fromSeed(
                  seedColor: Colors.blue,
                  brightness: brightness,
                ),
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showAppDialog<bool>(
                      context: context,
                      builder: (context) => AppDialog(
                        title: const Text('删除消息？'),
                        content: const Text('此操作会删除所选消息。'),
                        icon: const Icon(Icons.delete_outline),
                        destructive: true,
                        cancelLabel: '取消',
                        onCancel: () => Navigator.pop(context, false),
                        confirmLabel: '删除',
                        onConfirm: () => Navigator.pop(context, true),
                      ),
                    ),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await _preview(tester, capture, 'dialog-${brightness.name}.png');
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
      }
    },
  );
}

Future<void> _preview(WidgetTester tester, GlobalKey key, String name) async {
  final directory = Platform.environment['MICA_DIALOG_PREVIEW_DIR'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ImageByteFormat.png);
    await File('$directory/$name').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
