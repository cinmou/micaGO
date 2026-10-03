# Release Packaging

Current release version: `0.87.0` (codename Muscovite).

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
VERSION=0.87.0 scripts/package-dmg.sh
```

Signed DMG with the local Developer ID certificate (keeps the same code
signature as published builds, so macOS privacy grants such as Full Disk Access
carry over when it replaces an installed copy):

```sh
cd MicaGoServer/micago-mac-companion
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
APPLE_TEAM_ID="TEAMID" \
VERSION=0.87.0 \
scripts/package-dmg.sh
```

Release DMG (signed, notarized, with the Sparkle appcast). Store the notary
credentials once with
`xcrun notarytool store-credentials "micaGO-notary" --apple-id <id> --team-id TEAMID`;
the Sparkle EdDSA key is read from the login keychain:

```sh
cd MicaGoServer/micago-mac-companion
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
APPLE_TEAM_ID="TEAMID" \
NOTARIZE=1 \
NOTARY_KEYCHAIN_PROFILE="micaGO-notary" \
GENERATE_APPCAST=1 \
VERSION=0.87.0 \
scripts/package-dmg.sh
```

Upload `build/release/micaGO-Companion-0.87.0-mac.dmg` and
`build/release/appcast.xml` from the same run — the appcast's signature and
length only match that exact DMG.

The DMG is styled as a standard drag-to-install disk image: it contains the
Companion app, an `Applications` shortcut, and a Finder background image.

The output is:

```text
MicaGoServer/micago-mac-companion/build/release/micaGO-Companion-0.87.0-mac.dmg
```

Toolchain notes:

- The Companion is built for `generic/platform=macOS`, so the app is universal
  (Apple silicon + Intel), matching the universal bundled backend.
- The Go backend links through cgo. When macOS is newer than the installed
  Xcode, Xcode's linker cannot read the Command Line Tools' newer SDK, so the Go
  step uses the Command Line Tools toolchain automatically. Override with
  `GO_DEVELOPER_DIR=/path/to/Developer` if needed.
- The backend is built for macOS 13.0 (`BACKEND_MIN_MACOS`), matching the
  Companion. Without it, cgo targets the build machine's macOS and the bundled
  server refuses to start on older systems. The script prints the per-arch
  minimum so it can be checked in the build log. `ld: warning: ... built for
  newer 'macOS' version` lines printed during the Xcode step come from the
  project's "Bundle Go Backend" Run Script phase; that binary is replaced by the
  script's universal backend before signing.

## Flutter Android

Release APK:

```sh
cd MicaGoFlutterClient
flutter pub get
flutter build apk --release --build-name 0.87.0 --build-number 87
```

Output:

```text
MicaGoFlutterClient/build/app/outputs/flutter-apk/app-release.apk
```

Release App Bundle for Play-style distribution:

```sh
cd MicaGoFlutterClient
flutter build appbundle --release --build-name 0.87.0 --build-number 87
```

Output:

```text
MicaGoFlutterClient/build/app/outputs/bundle/release/app-release.aab
```

## Windows

The Windows client is the native WinUI app in `MicaGoWindowsClient`. The release
workflow's `windows` job builds it on `windows-latest` (.NET 10 via
`actions/setup-dotnet`), runs the Core contract tests, and uploads
`micaGO-<version>-Windows-release.zip`. To package locally on a Windows machine:

```powershell
.\MicaGoWindowsClient\scripts\package-release-x64.ps1
```

Output: `MicaGoWindowsClient\artifacts\micaGO-release-x64.zip`. The website's
Windows button links the first release asset whose name contains `windows` and
ends in `.exe` (preferred) or `.zip`.

## GitHub Release

The workflow lives at:

```text
.github/workflows/release.yml
```

Run it manually from GitHub Actions, or push a tag:

```sh
git tag v0.87.0
git push origin v0.87.0
```

The workflow builds:

- Flutter Android release APK (`micaGO-<version>-android-release.apk`). It needs the `ANDROID_KEYSTORE_BASE64`,
  `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD`
  repository secrets; tag builds fail without them, manual runs only analyze
  and test.
- Windows x64 zip of the WinUI client (`micaGO-<version>-Windows-release.zip`).
- Unsigned iOS IPA (`micaGO-<version>-iOS-release-unsigned.ipa`) and an
  experimental Linux tarball (`micaGO-<version>-Linux-release.tar.gz`).

It only uploads these as workflow-run artifacts — it never creates or publishes
a GitHub Release. Download them from the run page and create the release by
hand.

The macOS Companion is not built in CI. Sign, notarize and generate
`appcast.xml` locally (see "Mac Companion DMG"), attach the DMG
(`micaGO-Companion-<version>-mac.dmg`) and `appcast.xml` to the release
together with the CI artifacts, then publish it. The Companion's in-app
updater reads
`https://github.com/cinmou/MicaGo/releases/latest/download/appcast.xml`, so the
release must not be published without that appcast.

## Historical Release Notes Example (0.62.0)

```md
## micaGO 0.62.0 Beta

This is a beta release for early testing and feedback. It is not yet a stable production release.

### Highlights
- FCM push now uses data-only delivery so Android renders the same local MessagingStyle notification surface as the keep-alive path.
- Upgraded relay databases with older paired-device rows no longer break `/api/devices` or test notifications.
- Firebase setup docs now cover granting `Firebase Cloud Messaging API Admin` to the service account.
- Test notification failures now surface clearer Firebase IAM errors.
- Version numbers are aligned at 0.62.0 across the client, backend, Companion, and release packaging.

### Install
- macOS: download `micaGO-0.62.0-mac.dmg`, drag micaGO into Applications, then grant Full Disk Access when prompted.
- Android: install `app-release.apk`, then pair with the Mac Companion.

### Known Notes
- macOS Gatekeeper requires signed and notarized builds for a smooth public release.
- Android production distribution should use a real release keystore instead of debug signing.
- UI and sync behavior may still change before the first stable release.
```
