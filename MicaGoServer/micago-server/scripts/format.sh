#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

find . -name '*.go' -not -path './.gocache/*' -print0 | xargs -0 gofmt -w
