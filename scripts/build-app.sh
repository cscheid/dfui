#!/usr/bin/env bash
# Builds dfui and wraps the executable in a minimal .app bundle.
#
# A bare SwiftPM executable can put an item in the menu bar, but macOS only
# treats it as a proper agent (no Dock icon, launchable from Finder, able to
# be a login item) when it lives in a bundle with LSUIElement set.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="dist/dfui.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/dfui"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/dfui"
cp resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature: unsigned binaries get killed on arm64, and re-signing on
# every build keeps macOS from caching a stale identity for the bundle.
codesign --force --sign - "$APP"

echo "built $APP"
