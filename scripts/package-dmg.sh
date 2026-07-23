#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
STAGING="$DIST/staging"
APP="$STAGING/Codex Monitor.app"
ASSETS="$DIST/assets"
ICONSET="$ASSETS/AppIcon.iconset"
RW_DMG="$DIST/CodexMonitor-rw.dmg"
FINAL_DMG="$DIST/CodexMonitor-0.4.8.dmg"
VOLUME_NAME="Codex Monitor Installer"
BUILD_VOLUME_NAME="Codex Monitor Build $$"
MOUNT_DEVICE=""

cleanup_mount() {
  if [[ -n "$MOUNT_DEVICE" ]]; then
    hdiutil detach "$MOUNT_DEVICE" >/dev/null 2>&1 || true
  fi
}
trap cleanup_mount EXIT

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
swift build -c release --product CodexMonitorHook
BIN_PATH="$(swift build -c release --show-bin-path)"
cp "$BIN_PATH/CodexMonitor" "$APP/Contents/MacOS/CodexMonitor"
cp "$BIN_PATH/CodexMonitorHook" "$APP/Contents/Resources/CodexMonitorHook"
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
for frame_prefix in cat-frame idle-frame thinking-frame waiting-frame; do
  for frame_index in {0..4}; do
    frame_path="$FRAME_DIR/$frame_prefix-$frame_index.png"
    if [[ ! -f "$frame_path" ]]; then
      print -u2 -- "error: missing animation frame: $frame_path"
      exit 1
    fi
  done
done
if [[ -f "$FRAME_DIR/elthen-idle-frame-0.png" ]]; then
  for entry in \
    "elthen-idle-frame 0 3" \
    "elthen-thinking-frame 0 3" \
    "elthen-working-frame 0 7" \
    "elthen-waiting-frame 0 5" \
    "elthen-transition-idle-frame 0 5" \
    "elthen-transition-thinking-frame 0 5" \
    "elthen-transition-working-frame 0 5" \
    "elthen-transition-waiting-frame 0 5"
  do
    frame_prefix="${entry%% *}"
    range="${entry#* }"
    first_index="${range%% *}"
    last_index="${range#* }"
    for ((frame_index = first_index; frame_index <= last_index; frame_index++)); do
      frame_path="$FRAME_DIR/$frame_prefix-$frame_index.png"
      if [[ ! -f "$frame_path" ]]; then
        print -u2 -- "error: missing Elthen animation frame: $frame_path"
        exit 1
      fi
    done
  done
fi
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"

codesign --force --deep --sign - "$APP"
hdiutil create -volname "$BUILD_VOLUME_NAME" -srcfolder "$STAGING" -ov -format UDRW "$RW_DMG"
ATTACH_OUTPUT="$(hdiutil attach -readwrite -noverify -nobrowse "$RW_DMG")"
MOUNT_POINT="$(print -r -- "$ATTACH_OUTPUT" | awk -F '\t' '/\/Volumes\// {print $NF}' | tail -1)"
MOUNT_DEVICE="$(print -r -- "$ATTACH_OUTPUT" | awk 'NR == 1 {print $1}')"
mkdir -p "$MOUNT_POINT/.background"
cp "$ASSETS/install-background.png" "$MOUNT_POINT/.background/install-background.png"
chflags hidden "$MOUNT_POINT/.background"

osascript - "$BUILD_VOLUME_NAME" <<'APPLESCRIPT'
on run argv
    set buildVolumeName to item 1 of argv
    tell application "Finder"
        tell disk buildVolumeName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set bounds of container window to {100, 100, 860, 520}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 120
            set text size of viewOptions to 13
            set background picture of viewOptions to file ".background:install-background.png"
            set position of item "Codex Monitor.app" to {190, 250}
            set position of item "Applications" to {570, 250}
            update without registering applications
            delay 2
            close
        end tell
    end tell
end run
APPLESCRIPT

sync
if [[ ! -f "$MOUNT_POINT/.DS_Store" ]]; then
  print -u2 -- "error: Finder installer layout was not saved to $MOUNT_POINT/.DS_Store"
  exit 1
fi
diskutil rename "$MOUNT_POINT" "$VOLUME_NAME" >/dev/null
hdiutil detach "$MOUNT_DEVICE"
MOUNT_DEVICE=""
hdiutil convert "$RW_DMG" -format UDZO -o "$FINAL_DMG"
rm -f "$RW_DMG"
trap - EXIT
