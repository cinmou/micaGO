import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/ui/top_banner.dart';

void main() {
  testWidgets(
    'TopBanner appears below the title bar without shifting the body',
    (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(title: const Text('micaGO')),
            body: Builder(
              builder: (context) {
                ctx = context;
                return const SizedBox.expand(key: Key('body'));
              },
            ),
          ),
        ),
      );

      final bodyY = tester.getTopLeft(find.byKey(const Key('body'))).dy;
      TopBanner.show(ctx, 'Connection lost');
      await tester.pump(); // insert overlay
      await tester.pump(const Duration(milliseconds: 250)); // finish slide-in

      expect(find.text('Connection lost'), findsOneWidget);

      final titleBarBottom = tester.getBottomLeft(find.byType(AppBar)).dy;
      expect(
        tester.getTopLeft(find.text('Connection lost')).dy,
        greaterThanOrEqualTo(titleBarBottom + 8),
      );
      expect(tester.getTopLeft(find.byKey(const Key('body'))).dy, bodyY);
      // The banner remains near the top.
      final bannerY = tester.getTopLeft(find.text('Connection lost')).dy;
      final screenH =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      expect(bannerY, lessThan(screenH / 2));
      await tester.pump(const Duration(seconds: 4));
    },
  );

  testWidgets('top Undo lasts five seconds and completes before dismissal', (
    tester,
  ) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('micaGO')),
          body: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    var actions = 0;
    var closed = false;
    final action = Completer<void>();
    final notice = TopBanner.show(
      ctx,
      'Hidden with undo',
      duration: const Duration(seconds: 5),
      actionLabel: 'Undo',
      onAction: () {
        actions++;
        return action.future;
      },
    );
    unawaited(notice.then((_) => closed = true));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Undo'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.tap(find.text('Undo'));
    expect(actions, 1);
    expect(closed, false);
    action.complete();
    await tester.pumpAndSettle();
    expect(closed, true);
    expect(find.text('Undo'), findsNothing);
  });

  testWidgets('transient errors use the same neutral notice surface', (
    tester,
  ) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    TopBanner.show(ctx, 'Action failed', kind: TopBannerKind.error);
    await tester.pumpAndSettle();
    final card = tester.widget<AppNoticeCard>(find.byType(AppNoticeCard));
    expect(card.kind, TopBannerKind.info);
    expect(find.byIcon(Icons.error_outline), findsNothing);
    TopBanner.dismiss();
    await tester.pump();
  });

  testWidgets('identical messages do not stack (de-duped)', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );

    TopBanner.show(ctx, 'Send failed');
    await tester.pump();
    TopBanner.show(ctx, 'Send failed'); // repeat within the window
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Send failed'), findsOneWidget);

    // Let it auto-dismiss so it doesn't leak into other tests.
    await tester.pump(const Duration(seconds: 4));
  });
}
