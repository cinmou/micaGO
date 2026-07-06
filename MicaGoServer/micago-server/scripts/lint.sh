#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

unformatted="$(gofmt -l .)"
if [[ -n "$unformatted" ]]; then
  echo "Go files need gofmt:"
  echo "$unformatted"
  exit 1
fi

go vet ./...
