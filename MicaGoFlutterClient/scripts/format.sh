#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

dart --suppress-analytics format lib test
