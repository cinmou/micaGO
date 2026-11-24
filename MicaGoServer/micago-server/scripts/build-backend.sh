#!/bin/sh
# Build the MicaGo backend with full build identity (version/commit/buildTime)
# and install it where the companion looks for it (~/.micago/bin/micago by
# default; pass a different output path as $1).
#
# This is THE supported way to refresh the dev backend — a plain `go build`
# works but loses the commit/buildTime stamp the companion uses to detect
# stale binaries (C17).
set -eu

cd "$(dirname "$0")/.."

COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  COMMIT="${COMMIT}-dirty"
fi
BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OUT="${1:-$HOME/.micago/bin/micago}"

# cgo links the backend with the system toolchain. On a macOS newer than the
# selected Xcode, xcrun pairs Xcode's older linker with the Command Line Tools'
# newer SDK and linking fails; the Command Line Tools linker matches its own SDK.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -x /Library/Developer/CommandLineTools/usr/bin/clang ]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
# Without an explicit target, cgo's C objects target the build host's macOS and
# the binary refuses to launch on older systems.
BACKEND_MIN_MACOS="${BACKEND_MIN_MACOS:-13.0}"
export MACOSX_DEPLOYMENT_TARGET="$BACKEND_MIN_MACOS"
export CGO_CFLAGS="${CGO_CFLAGS:--O2} -mmacosx-version-min=$BACKEND_MIN_MACOS"
export CGO_LDFLAGS="${CGO_LDFLAGS:--O2} -mmacosx-version-min=$BACKEND_MIN_MACOS"

mkdir -p "$(dirname "$OUT")"
export GOCACHE="${GOCACHE:-$PWD/.gocache}"
go build \
  -trimpath \
  -ldflags "-s -w -X micagoserver/internal/version.Commit=$COMMIT -X micagoserver/internal/version.BuildTime=$BUILD_TIME" \
  -o "$OUT" ./cmd/micago

echo "built: $OUT"
"$OUT" --version
