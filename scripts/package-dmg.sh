#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
STAGING="$DIST/staging"
APP="$STAGING/Codex Monitor.app"

rm -rf "$STAGING"
mkdir -p "$APP/Contents/MacOS"

cd "$ROOT"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)"
cp "$BIN_PATH/CodexMonitor" "$APP/Contents/MacOS/CodexMonitor"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"

codesign --force --deep --sign - "$APP"
hdiutil create -volname "Codex Monitor" -srcfolder "$STAGING" -ov -format UDZO "$DIST/CodexMonitor-0.1.1.dmg"
