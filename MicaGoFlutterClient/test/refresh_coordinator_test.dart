import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/network/refresh_coordinator.dart';
import 'package:mica_go/core/network/websocket_client.dart';

void main() {
  group('reconnect backoff (pure)', () {
    test('grows then caps at 15s', () {
      expect(reconnectBackoff(0), const Duration(seconds: 1));
      expect(reconnectBackoff(1), const Duration(seconds: 2));
      expect(reconnectBackoff(2), const Duration(seconds: 5));
      expect(reconnectBackoff(4), const Duration(seconds: 15));
      expect(reconnectBackoff(99), const Duration(seconds: 15));
    });
  });

  group('RefreshCoordinator', () {
    test('fallback poll starts ONLY when WS is down, stops on reconnect', () {
      fakeAsync((async) {
        var status = WsStatus.connected;
        var polls = 0;
        var reconnects = 0;
        final c = RefreshCoordinator(
          reconnect: () async => reconnects++,
          catchUp: (_) async => polls++,
          wsStatus: () => status,
          fallbackPollInterval: const Duration(seconds: 5),
        );

        // Connected → no poll.
        c.onWsStatusChanged(WsStatus.connected);
        expect(c.isPolling, isFalse);
        async.elapse(const Duration(seconds: 12));
        expect(polls, 0);

        // Goes down → poll starts and fires while still down.
        status = WsStatus.disconnected;
        c.onWsStatusChanged(WsStatus.disconnected);
        expect(c.isPolling, isTrue);
        async.elapse(const Duration(seconds: 11)); // 2 poll ticks
        expect(polls, greaterThanOrEqualTo(2));

        // Comes back → next tick stops the poll.
        status = WsStatus.connected;
        c.onWsStatusChanged(WsStatus.connected);
        expect(c.isPolling, isFalse);
        final pollsAfter = polls;
        async.elapse(const Duration(seconds: 20));
        expect(polls, pollsAfter, reason: 'no polling once reconnected');

        c.dispose();
      });
    });

    test('schedules a reconnect after a disconnect (backoff)', () {
      fakeAsync((async) {
        var status = WsStatus.disconnected;
        var reconnects = 0;
        final c = RefreshCoordinator(
          reconnect: () async => reconnects++,
          catchUp: (_) async {},
          wsStatus: () => status,
          fallbackPollInterval: const Duration(seconds: 60),
        );

        c.onWsStatusChanged(WsStatus.disconnected);
        expect(reconnects, 0);
        async.elapse(const Duration(seconds: 2)); // first backoff = 1s
        expect(reconnects, 1, reason: 'reconnect fired after backoff');

        c.dispose();
      });
    });

    test(
      'a reconnect is NOT fired if the socket recovered before the timer',
      () {
        fakeAsync((async) {
          var status = WsStatus.disconnected;
          var reconnects = 0;
          final c = RefreshCoordinator(
            reconnect: () async => reconnects++,
            catchUp: (_) async {},
            wsStatus: () => status,
          );

          c.onWsStatusChanged(WsStatus.disconnected);
          // Recover before the backoff elapses.
          status = WsStatus.connected;
          c.onWsStatusChanged(WsStatus.connected);
          async.elapse(const Duration(seconds: 30));
          expect(reconnects, 0);

          c.dispose();
        });
      },
    );

    test(
      'overlapping resumes share reconnect and wait before catch-up',
      () async {
        final ready = Completer<void>();
        var reconnects = 0;
        var polls = 0;
        final c = RefreshCoordinator(
          reconnect: () {
            reconnects++;
            return ready.future;
          },
          catchUp: (_) async {
            polls++;
          },
          wsStatus: () => WsStatus.disconnected,
        );
        final first = c.onResume();
        final second = c.onResume();
        expect(reconnects, 1);
        expect(polls, 0);
        ready.complete();
        await Future.wait([first, second]);
        expect(polls, 1);
        c.dispose();
      },
    );

    test('onResume reconnects before catching up', () async {
      var status = WsStatus.disconnected;
      var reconnects = 0;
      final reasons = <String>[];
      final c = RefreshCoordinator(
        reconnect: () async => reconnects++,
        catchUp: (r) async => reasons.add(r),
        wsStatus: () => status,
      );

      await c.onResume();
      expect(reconnects, 1);
      expect(reasons, contains('resume'));

      // When already connected, resume only catches up.
      status = WsStatus.connected;
      reconnects = 0;
      await c.onResume();
      expect(reconnects, 0);
      expect(reasons.where((r) => r == 'resume').length, 2);

      c.dispose();
    });
  });
}
