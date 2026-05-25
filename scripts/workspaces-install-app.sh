#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

APP_NAME="Ghostty-Workspaces"
DISPLAY_NAME="Ghostty Workspaces"
BUNDLE_ID="com.ramonvg.ghostty-workspaces"
SOURCE_APP="macos/build/ReleaseLocal/Ghostty.app"
DEST_APP="/Applications/${APP_NAME}.app"

# Build an optimized side-by-side app so the debug performance warning is gone.
env DEVELOPER_DIR=/Library/Developer/CommandLineTools \
    zig build -Doptimize=ReleaseFast -Dxcframework-target=native

rm -rf "$DEST_APP"
cp -R "$SOURCE_APP" "$DEST_APP"

/usr/libexec/PlistBuddy -c "Set :CFBundleName ${DISPLAY_NAME}" "$DEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${DISPLAY_NAME}" "$DEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "$DEST_APP/Contents/Info.plist"

xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
codesign --force --deep --sign - "$DEST_APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST_APP"

open "$DEST_APP"
