#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

"$ROOT/MicaGoServer/micago-server/scripts/lint.sh"
"$ROOT/MicaGoServer/micago-mac-companion/scripts/lint.sh"
"$ROOT/MicaGoFlutterClient/scripts/lint.sh"
