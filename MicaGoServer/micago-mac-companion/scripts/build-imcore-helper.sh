#!/bin/sh
# Compile the micaGO IMCore helper (edit / unsend / delete) to a standalone
# binary. The Companion's Xcode build phase calls this to bundle it into the app
# Resources; you can also run it directly to test the compile.
#
# Usage: scripts/build-imcore-helper.sh [output-path]
#   default output: <repo>/MicaGoServer/micago-mac-companion/build/micago-imcore-helper
set -eu

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$DIR/helper/micago-imcore-helper.m"
OUT="${1:-$DIR/build/micago-imcore-helper}"

mkdir -p "$(dirname "$OUT")"

# Foundation + the ObjC runtime only; IMCore is loaded at runtime via dlopen, so
# no private framework needs to be linked (keeps the build + signing standard).
clang -fobjc-arc -mmacosx-version-min=12.0 \
    -framework Foundation \
    -o "$OUT" "$SRC"

chmod +x "$OUT"
echo "built micago-imcore-helper -> $OUT"
