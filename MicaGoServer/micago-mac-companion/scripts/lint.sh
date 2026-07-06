#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

swift format lint \
  --configuration .swift-format \
  --recursive \
  MicaGoCompanion scripts/tests scripts/make-dmg-background.swift
