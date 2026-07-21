#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
STAGING="$DIST/staging"
APP="$STAGING/Codex Monitor.app"
ASSETS="$DIST/assets"
ICONSET="$ASSETS/AppIcon.iconset"
RW_DMG="$DIST/CodexMonitor-rw.dmg"
FINAL_DMG="$DIST/CodexMonitor-0.3.2.dmg"
VOLUME_NAME="Codex Monitor Installer"

rm -rf "$STAGING" "$ASSETS" "$RW_DMG" "$FINAL_DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ICONSET"
ln -s /Applications "$STAGING/Applications"

swift "$ROOT/scripts/create-artwork.swift" "$ASSETS/AppIcon-1024.png" "$ASSETS/install-background.png"
for entry in \
  "16 icon_16x16" \
  "32 icon_16x16@2x" \
  "32 icon_32x32" \
  "64 icon_32x32@2x" \
  "128 icon_128x128" \
  "256 icon_128x128@2x" \
  "256 icon_256x256" \
  "512 icon_256x256@2x" \
  "512 icon_512x512" \
  "1024 icon_512x512@2x"
do
  size="${entry%% *}"
  name="${entry#* }"
  sips -z "$size" "$size" "$ASSETS/AppIcon-1024.png" --out "$ICONSET/$name.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cd "$ROOT"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)"
cp "$BIN_PATH/CodexMonitor" "$APP/Contents/MacOS/CodexMonitor"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
RESOURCE_BUNDLE="$BIN_PATH/CodexMonitor_CodexMonitor.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
fi
COPIED_RESOURCE_BUNDLE="$APP/Contents/Resources/CodexMonitor_CodexMonitor.bundle"
NATIVE_FRAME_DIR="$COPIED_RESOURCE_BUNDLE/Contents/Resources/CatFrames"
FLAT_FRAME_DIR="$COPIED_RESOURCE_BUNDLE/CatFrames"
if [[ -d "$NATIVE_FRAME_DIR" ]]; then
  FRAME_DIR="$NATIVE_FRAME_DIR"
elif [[ -d "$FLAT_FRAME_DIR" ]]; then
  FRAME_DIR="$FLAT_FRAME_DIR"
else
  print -u2 -- "error: animation frame directory not found at $NATIVE_FRAME_DIR or $FLAT_FRAME_DIR"
  exit 1
fi
for frame_index in {0..4}; do
  frame_path="$FRAME_DIR/cat-frame-$frame_index.png"
  if [[ ! -f "$frame_path" ]]; then
    print -u2 -- "error: missing animation frame: $frame_path"
    exit 1
  fi
done
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"

codesign --force --deep --sign - "$APP"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING" -ov -format UDRW "$RW_DMG"
MOUNT_POINT="$(hdiutil attach -readwrite -noverify -nobrowse "$RW_DMG" | awk -F '\t' '/\/Volumes\// {print $NF}')"
mkdir -p "$MOUNT_POINT/.background"
cp "$ASSETS/install-background.png" "$MOUNT_POINT/.background/install-background.png"
chflags hidden "$MOUNT_POINT/.background"

osascript <<'APPLESCRIPT'
tell application "Finder"
    tell disk "Codex Monitor Installer"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 860, 560}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 14
        set background picture of viewOptions to file ".background:install-background.png"
        set position of item "Codex Monitor.app" to {190, 285}
        set position of item "Applications" to {570, 285}
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_POINT"
hdiutil convert "$RW_DMG" -format UDZO -o "$FINAL_DMG"
rm -f "$RW_DMG"
