#!/bin/zsh
# Build micaGO Companion.app with a bundled universal Go backend, then create a DMG.
#
# Unsigned local build:
#   ./scripts/package-dmg.sh
#
# Signed + notarized build:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARIZE=1 APPLE_ID="you@example.com" APPLE_TEAM_ID="TEAMID" \
#   APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx" ./scripts/package-dmg.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPANION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER_DIR="$(cd "$COMPANION_DIR/../micago-server" && pwd)"
VERSION="${VERSION:-0.59.0}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="${DERIVED_DATA:-$COMPANION_DIR/build/DerivedData}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$COMPANION_DIR/build/release}"
BACKEND_DIR="$ARTIFACT_DIR/backend"
APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/MicaGoCompanion.app"
DMG_PATH="$ARTIFACT_DIR/micaGO-$VERSION-mac.dmg"
DMG_STAGING_DIR="$ARTIFACT_DIR/dmg-staging"
DMG_BACKGROUND_PATH="$ARTIFACT_DIR/dmg-background.png"
SWIFT_MODULE_CACHE_DIR="$ARTIFACT_DIR/swift-module-cache"
DMG_VOLUME_NAME="${DMG_VOLUME_NAME:-micaGO}"
DMG_APP_NAME="${DMG_APP_NAME:-micaGO Companion.app}"
DMG_WINDOW_WIDTH="${DMG_WINDOW_WIDTH:-}"
DMG_WINDOW_HEIGHT="${DMG_WINDOW_HEIGHT:-}"
DMG_WINDOW_SCALE="${DMG_WINDOW_SCALE:-100}"

mkdir -p "$BACKEND_DIR" "$ARTIFACT_DIR"

COMMIT="$(cd "$SERVER_DIR" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(cd "$SERVER_DIR" && git status --porcelain 2>/dev/null)" ]; then
  COMMIT="${COMMIT}-dirty"
fi
BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LDFLAGS="-X micagoserver/internal/version.Commit=$COMMIT -X micagoserver/internal/version.BuildTime=$BUILD_TIME"

echo "==> Building universal Go backend ($VERSION)"
(
  cd "$SERVER_DIR"
  export GOCACHE="${GOCACHE:-$SERVER_DIR/.gocache}"
  GOOS=darwin GOARCH=arm64 go build -ldflags "$LDFLAGS" -o "$BACKEND_DIR/micago-arm64" ./cmd/micago
  GOOS=darwin GOARCH=amd64 go build -ldflags "$LDFLAGS" -o "$BACKEND_DIR/micago-amd64" ./cmd/micago
)
lipo -create -output "$BACKEND_DIR/micago" "$BACKEND_DIR/micago-arm64" "$BACKEND_DIR/micago-amd64"
chmod +x "$BACKEND_DIR/micago"
"$BACKEND_DIR/micago" --version

echo "==> Building micaGO Companion.app"
XCODE_SIGNING_ARGS=()
if [ -z "${SIGN_IDENTITY:-}" ]; then
  XCODE_SIGNING_ARGS=(
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGN_IDENTITY=-
  )
fi
xcodebuild \
  -project "$COMPANION_DIR/MicaGoCompanion.xcodeproj" \
  -scheme MicaGoCompanion \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  "${XCODE_SIGNING_ARGS[@]}" \
  build

if [ ! -d "$APP_PATH" ]; then
  echo "error: app not found at $APP_PATH" >&2
  exit 1
fi

echo "==> Installing bundled backend"
mkdir -p "$APP_PATH/Contents/Resources"
cp "$BACKEND_DIR/micago" "$APP_PATH/Contents/Resources/micago"
chmod +x "$APP_PATH/Contents/Resources/micago"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  echo "==> Signing bundled executables and app"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_PATH/Contents/Resources/micago"
  if [ -f "$APP_PATH/Contents/Resources/micago-imcore-helper" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_PATH/Contents/Resources/micago-imcore-helper"
  fi
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_PATH"
else
  echo "==> SIGN_IDENTITY not set; leaving app unsigned for local testing"
fi

echo "==> Creating DMG"
if ! command -v create-dmg >/dev/null 2>&1; then
  echo "error: create-dmg is required. Install it with: brew install create-dmg" >&2
  exit 1
fi

rm -f "$DMG_PATH"
rm -rf "$DMG_STAGING_DIR"
mkdir -p "$DMG_STAGING_DIR"

ditto "$APP_PATH" "$DMG_STAGING_DIR/$DMG_APP_NAME"
if [ ! -f "$DMG_BACKGROUND_PATH" ]; then
  mkdir -p "$SWIFT_MODULE_CACHE_DIR"
  CLANG_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE_DIR" \
    swift "$SCRIPT_DIR/make-dmg-background.swift" "$DMG_BACKGROUND_PATH"
fi

if [ -z "$DMG_WINDOW_WIDTH" ]; then
  DMG_WINDOW_WIDTH="$(sips -g pixelWidth "$DMG_BACKGROUND_PATH" 2>/dev/null | awk '/pixelWidth/ {print $2}')"
fi
if [ -z "$DMG_WINDOW_HEIGHT" ]; then
  DMG_WINDOW_HEIGHT="$(sips -g pixelHeight "$DMG_BACKGROUND_PATH" 2>/dev/null | awk '/pixelHeight/ {print $2}')"
fi
DMG_WINDOW_WIDTH="${DMG_WINDOW_WIDTH:-660}"
DMG_WINDOW_HEIGHT="${DMG_WINDOW_HEIGHT:-420}"
if [ "$DMG_WINDOW_SCALE" -gt 0 ] && [ "$DMG_WINDOW_SCALE" -ne 100 ]; then
  DMG_WINDOW_WIDTH=$((DMG_WINDOW_WIDTH * DMG_WINDOW_SCALE / 100))
  DMG_WINDOW_HEIGHT=$((DMG_WINDOW_HEIGHT * DMG_WINDOW_SCALE / 100))
fi
APP_ICON_X=$((DMG_WINDOW_WIDTH * 27 / 100))
APP_ICON_Y=$((DMG_WINDOW_HEIGHT * 49 / 100))
APPLICATIONS_ICON_X=$((DMG_WINDOW_WIDTH * 73 / 100))
APPLICATIONS_ICON_Y="$APP_ICON_Y"

create-dmg \
  --volname "$DMG_VOLUME_NAME" \
  --background "$DMG_BACKGROUND_PATH" \
  --window-pos 100 100 \
  --window-size "$DMG_WINDOW_WIDTH" "$DMG_WINDOW_HEIGHT" \
  --icon-size 96 \
  --icon "$DMG_APP_NAME" "$APP_ICON_X" "$APP_ICON_Y" \
  --hide-extension "$DMG_APP_NAME" \
  --app-drop-link "$APPLICATIONS_ICON_X" "$APPLICATIONS_ICON_Y" \
  --no-internet-enable \
  --hdiutil-quiet \
  --overwrite \
  "$DMG_PATH" \
  "$DMG_STAGING_DIR"

rm -rf "$DMG_STAGING_DIR"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
fi

if [ "${NOTARIZE:-0}" = "1" ]; then
  : "${APPLE_ID:?APPLE_ID is required when NOTARIZE=1}"
  : "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required when NOTARIZE=1}"
  : "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD is required when NOTARIZE=1}"
  echo "==> Notarizing DMG"
  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait
  xcrun stapler staple "$DMG_PATH"
fi

echo "DMG: $DMG_PATH"
