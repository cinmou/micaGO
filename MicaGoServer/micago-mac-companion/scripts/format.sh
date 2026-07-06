#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

swift format format \
  --configuration .swift-format \
  --recursive \
  --in-place \
  MicaGoCompanion scripts/tests scripts/make-dmg-background.swift
