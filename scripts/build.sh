#!/usr/bin/env bash
# Builds Porthole.app and a DMG in ./build.
#
#   scripts/build.sh                      ad-hoc signed, for local use
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE=porthole scripts/build.sh   signed and notarized, for release
#
# NOTARY_PROFILE is a keychain profile created once with
#   xcrun notarytool store-credentials porthole --apple-id you@example.com --team-id TEAMID
set -euo pipefail
cd "$(dirname "$0")/.."

APP=Porthole
VERSION=${VERSION:-0.1.0}
BUILD=${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
BUNDLE_ID=${BUNDLE_ID:-io.github.infrasan.porthole}
OUT=build
APP_DIR="$OUT/$APP.app"
DMG="$OUT/$APP-$VERSION.dmg"

echo "› Compiling (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64 >/dev/null
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP"

echo "› Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/$APP"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" -e "s/__BUNDLE_ID__/$BUNDLE_ID/" \
    Resources/Info.plist > "$APP_DIR/Contents/Info.plist"
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
cp Resources/Assets.xcassets/AppIcon.appiconset/*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "› Signing"
if [ -n "${DEVELOPER_ID:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP_DIR"
else
    codesign --force --sign - "$APP_DIR"
fi

echo "› Packaging $DMG"
scripts/make-dmg.sh "$APP_DIR" >/dev/null

if [ -n "${DEVELOPER_ID:-}" ]; then
    codesign --force --sign "$DEVELOPER_ID" "$DMG"
fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "› Notarizing (a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
