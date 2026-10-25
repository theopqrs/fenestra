#!/bin/bash
# Builds Fenestra.app into ./build. With --install, copies it to /Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Fenestra"
APP="build/$APP_NAME.app"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

if [ ! -f Resources/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# A real signing identity keeps the Accessibility / Screen Recording permissions across rebuilds.
# Ad-hoc signing works too, but macOS then asks for the permissions again after every build.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')}"
if [ -n "$IDENTITY" ] && codesign --force --timestamp=none --sign "$IDENTITY" "$APP" 2>/dev/null; then
  echo "Signé avec : $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "Signé ad hoc (les autorisations seront redemandées après chaque build)"
fi

if [ "${1:-}" = "--install" ]; then
  pkill -x "$APP_NAME" 2>/dev/null && sleep 1 || true
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  open "/Applications/$APP_NAME.app"
  echo "Installé dans /Applications et lancé."
else
  echo "App prête : $APP"
fi
