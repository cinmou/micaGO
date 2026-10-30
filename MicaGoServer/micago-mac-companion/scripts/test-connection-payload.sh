#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
TASK_TMP=$(mktemp -d)
trap 'rm -rf "$TASK_TMP"' EXIT
xcrun swiftc MicaGoCompanion/Services/ConnectionPayload.swift scripts/tests/main.swift -o "$TASK_TMP/test"
"$TASK_TMP/test"
