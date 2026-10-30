#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
TASK_TMP=$(mktemp -d)
trap 'rm -rf "$TASK_TMP"' EXIT
xcrun swiftc -parse-as-library \
  MicaGoCompanion/Services/APIClient.swift \
  MicaGoCompanion/Services/ContactsService.swift \
  MicaGoCompanion/ChatPreferenceStore.swift \
  MicaGoCompanion/Localization.swift \
  MicaGoCompanion/Models/*.swift \
  scripts/tests/api-client.swift -o "$TASK_TMP/test"
"$TASK_TMP/test"
