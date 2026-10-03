import 'package:go_router/go_router.dart';

import '../core/app_controller.dart';
import '../features/connection/connection_screen.dart';
import '../features/home/home_screen.dart';
import '../features/home/connection_notice_host.dart';
import '../features/pairing/qr_pairing_screen.dart';

/// Route names/paths for the app.
class Routes {
  Routes._();
  static const connection = '/connection';
  static const pair = '/pair';
  static const home = '/home';
}

/// Builds the app router. Guards send the user to the connection/pairing
/// screens until a complete profile exists; both stay reachable for editing.
GoRouter createRouter(AppController app) {
  return GoRouter(
    initialLocation: app.hasProfile ? Routes.home : Routes.connection,
    refreshListenable: app,
    redirect: (context, state) {
      // Wait until persisted state is loaded to avoid a flash of the wrong page.
      if (!app.bootstrapped && !app.tokenRejected.value) return null;
      final loc = state.matchedLocation;
      final onboarding = loc == Routes.connection || loc == Routes.pair;
      if (!app.hasProfile && !onboarding) {
        return Routes.connection;
      }
      return null;
    },
    routes: [
      ShellRoute(
        builder: (context, state, child) => ConnectionNoticeHost(child: child),
        routes: [
          GoRoute(
            path: Routes.connection,
            builder: (context, state) => const ConnectionScreen(),
          ),
          GoRoute(
            path: Routes.pair,
            builder: (context, state) => const QrPairingScreen(),
          ),
          GoRoute(
            path: Routes.home,
            builder: (context, state) => const HomeShell(),
          ),
        ],
      ),
    ],
  );
}
