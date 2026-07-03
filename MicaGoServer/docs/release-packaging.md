# Release Packaging

Current release version: `0.59.0`.

## Mac Companion DMG

The styled DMG depends on [`create-dmg`](https://github.com/create-dmg/create-dmg):

```sh
brew install create-dmg
```

The Companion app bundles the Go backend at:

```text
MicaGoCompanion.app/Contents/Resources/micago
```

Local unsigned DMG:

```sh
cd MicaGoServer/micago-mac-companion
VERSION=0.59.0 scripts/package-dmg.sh
```

Signed and notarized DMG:

```sh
cd MicaGoServer/micago-mac-companion
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARIZE=1 \
APPLE_ID="you@example.com" \
APPLE_TEAM_ID="TEAMID" \
APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
VERSION=0.59.0 \
scripts/package-dmg.sh
```

The DMG is styled as a standard drag-to-install disk image: it contains the
Companion app, an `Applications` shortcut, and a Finder background image.

The output is:

```text
MicaGoServer/micago-mac-companion/build/release/micaGO-0.59.0-mac.dmg
```

## Flutter Android

Release APK:

```sh
cd MicaGoFlutterClient
flutter pub get
flutter build apk --release --build-name 0.59.0 --build-number 59
```

Output:

```text
MicaGoFlutterClient/build/app/outputs/flutter-apk/app-release.apk
```

Release App Bundle for Play-style distribution:

```sh
cd MicaGoFlutterClient
flutter build appbundle --release --build-name 0.59.0 --build-number 59
```

Output:

```text
MicaGoFlutterClient/build/app/outputs/bundle/release/app-release.aab
```

## GitHub Release

The workflow lives at:

```text
.github/workflows/release.yml
```

Run it manually from GitHub Actions, or push a tag:

```sh
git tag v0.59.0
git push origin v0.59.0
```

The workflow builds:

- macOS DMG with bundled Go backend.
- Flutter Android release APK.
- A GitHub Release when triggered by a tag.

## Release Notes Template

```md
## micaGO 0.59.0 Beta

This is a beta release for early testing and feedback. It is not yet a stable production release.

### Highlights
- Settings backup and restore now cover the current client configuration, including connection details, appearance, chat background, custom avatars, muted chats, hidden items, message display options, tablet sidebar width, and FCM client options.
- Mac Companion adds a localized About page, a Developer Mode gate for Debug and Log, and a lifecycle setting to start and stop the bundled server with the app.
- Chat UI polish includes safer keyboard inset recovery, larger emoji/sticker display, tighter group-message spacing, and inserted image/GIF input support where the platform allows it.
- Version numbers are aligned at 0.59.0 across the client, backend, Companion, and release packaging.

### Install
- macOS: download `micaGO-0.59.0-mac.dmg`, drag micaGO into Applications, then grant Full Disk Access when prompted.
- Android: install `app-release.apk`, then pair with the Mac Companion.

### Known Notes
- macOS Gatekeeper requires signed and notarized builds for a smooth public release.
- Android production distribution should use a real release keystore instead of debug signing.
- UI and sync behavior may still change before the first stable release.
```
