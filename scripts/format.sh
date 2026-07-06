#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

"$ROOT/MicaGoServer/micago-server/scripts/format.sh"
"$ROOT/MicaGoServer/micago-mac-companion/scripts/format.sh"
"$ROOT/MicaGoFlutterClient/scripts/format.sh"
