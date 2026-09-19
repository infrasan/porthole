#!/usr/bin/env bash
# Wraps Porthole.app in a DMG with a shortcut to Applications.
# Usage: scripts/make-dmg.sh path/to/Porthole.app
# Use it on the app Xcode exports from Archive › Distribute App › Direct Distribution.
set -euo pipefail
APP_PATH=${1:?Usage: scripts/make-dmg.sh path/to/Porthole.app}
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
OUT="$(cd "$(dirname "$0")/.." && pwd)/build"
DMG="$OUT/Porthole-$VERSION.dmg"
mkdir -p "$OUT"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Porthole -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "$DMG"
