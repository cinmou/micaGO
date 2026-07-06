#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

dart --suppress-analytics format --output=none --set-exit-if-changed lib test
flutter --suppress-analytics analyze lib test
