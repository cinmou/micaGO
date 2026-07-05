# micaGO Android client (Flutter)

Android-first Flutter client for a **micaGO** relay server. Pair with your Mac
over LAN or an optional public URL, sync chats and messages, send text and
attachments, and (optionally) receive push notifications.

See the [root README](../README.md) for the project overview and the
[CHANGELOG](../MicaGoServer/docs/CHANGELOG.md) for the development history.

## Features

- **Pairing** — scan the Companion's QR code or paste its connection JSON;
  multiple LAN candidates with auto-select + a manual route switcher. The bearer
  token is stored in `flutter_secure_storage` (Android Keystore-backed) and never
  logged.
- **Chats & threads** — conversation list, message threads, reactions/tapbacks,
  replies, send effects, stickers, and inline image/video media with a
  full-screen viewer.
- **Sending** — text + attachments over iMessage; SMS when the server allows it.
- **Realtime + catch-up** — WebSocket events plus cursor-based delta sync to fill
  gaps after the app was closed.
- **Contacts matching** — opt-in, on-device name resolution (the address book is
  never uploaded).
- **Notifications (optional)** — Firebase/FCM push using your own project; a
  thin wake signal, with message data refreshed over the socket/delta path.
  Works without it.
- **Keep-alive (optional, advanced)** — a foreground service that keeps the
  connection alive in the background. Default off; Android/OEM battery policy can
  still throttle it.
- **Diagnostics** — Settings → Paired device debug (registration + connection
  diagnostics, "Register device now") and a realtime-event debug log.

## Architecture

```
lib/
  main.dart
  app/        mica_go_app.dart · router.dart · theme.dart
  core/
    app_controller.dart            # app-wide state (profile, clients, urls, registration)
    network/  api_client.dart · websocket_client.dart · connection_candidate.dart
              push_service.dart · push_logic.dart · device_identity.dart · …
    storage/  secure_store.dart · local_cache_store.dart (sqflite)
    models/   connection_profile.dart · server_urls.dart
  features/
    pairing/    QR scan + paste-JSON onboarding
    connection/ advanced manual setup + diagnostics
    chats/      thread, message render, attachments, media viewer, composer
    contacts/   on-device contact matching
    home/       app shell + connection notices
    settings/   appearance, SMS toggle, notifications, keep-alive, debug
    debug/       realtime event log
```

State: `ChangeNotifier` + `provider`. Routing: `go_router` (guards force the
connection screen until a complete profile exists).

## Server compatibility

Targets the micaGO relay API: a shared **bearer token**
(`Authorization: Bearer …`; the WebSocket also accepts `?token=`), the
connection-endpoints payload (`/api/server/urls`), chats/messages/delta, device
registry, message actions, and the optional FCM client config (`/api/fcm/client`).

## Run

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug      # or: flutter run -d <android-device>
```

## Notes

- `android:usesCleartextTraffic="true"` is enabled so the client can reach
  `http://` local/LAN servers; public access should use `https` via your tunnel.
- The bearer token is stored securely and never written to logs or `toString()`.
- Firebase, the keep-alive service, and the IMCore message actions are all
  optional and off by default. IMCore actions appear only when the Mac/helper
  reports them supported.
