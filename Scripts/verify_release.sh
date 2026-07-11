#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMP_OUTPUT_DIR=""

cleanup() {
    if [ -n "$TEMP_OUTPUT_DIR" ]; then
        rm -rf "$TEMP_OUTPUT_DIR"
    fi
}

trap cleanup EXIT

cd "$ROOT"

if [ -n "${APP_OUTPUT_DIR:-}" ]; then
    OUTPUT_DIR="$APP_OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"
    OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
else
    TEMP_OUTPUT_DIR="$(mktemp -d /tmp/tokenscope-verify-release.XXXXXX)"
    OUTPUT_DIR="$TEMP_OUTPUT_DIR"
fi

echo "==> swift test --parallel"
swift test --parallel

echo "==> usage reconciliation script tests"
python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'

echo "==> checking zh-Hans localization"
python3 Scripts/check_zh_hans_localization.py

echo "==> swift build (release)"
swift build -c release

echo "==> packaging TokenScope.app"
APP_OUTPUT_DIR="$OUTPUT_DIR" CONFIG=release Scripts/package_app.sh

echo "==> verifying TokenScope.app code signature"
codesign --verify --deep --strict --verbose=2 "$OUTPUT_DIR/TokenScope.app"
