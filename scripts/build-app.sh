#!/usr/bin/env bash
#
# Builds a distributable NetLights.app bundle (drop into /Applications) and a
# zip for GitHub Releases. Reuses the in-app SwiftUI icon to generate a real
# .icns — no external image tools required.
#
# Usage:  ./scripts/build-app.sh
# Output: dist/NetLights.app  and  dist/NetLights-<version>.zip
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="NetLights"
VERSION="1.4.0"
BUILD="6"
BUNDLE_ID="com.willowhawk.netlights"

DIST="dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "▸ Building release binary…"
swift build -c release

BIN=".build/release/$APP_NAME"
[ -f "$BIN" ] || { echo "✗ binary not found at $BIN"; exit 1; }

echo "▸ Assembling $APP …"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$BIN" "$MACOS/$APP_NAME"

echo "▸ Generating app icon (.icns)…"
ICONSET="$DIST/$APP_NAME.iconset"
rm -rf "$ICONSET"
# Run the freshly built binary in headless export mode to render the PNGs.
"$BIN" --export-iconset "$ICONSET" || true
# Give the GUI export a moment, then build the icns.
sleep 1
if [ -d "$ICONSET" ] && [ -n "$(ls -A "$ICONSET" 2>/dev/null)" ]; then
  iconutil -c icns "$ICONSET" -o "$RES/$APP_NAME.icns"
  rm -rf "$ICONSET"
else
  echo "  (icon export produced no files — bundle will use the runtime icon only)"
fi

echo "▸ Writing Info.plist…"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>        <string>$APP_NAME</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>         <string>$BUILD</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>NetLights uses your location only to read the current Wi-Fi network name (SSID), which macOS protects behind location access. No location coordinates are read, stored, or shared.</string>
</dict>
</plist>
PLIST

# Signing. Set SIGN_IDENTITY to a "Developer ID Application: …" identity for a
# real, distributable signature; otherwise an ad-hoc signature is used (users
# then right-click → Open the first time).
if [ -n "${SIGN_IDENTITY:-}" ]; then
  echo "▸ Signing with Developer ID (hardened runtime)…"
  codesign --force --deep --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$APP"
else
  echo "▸ Ad-hoc signing (set SIGN_IDENTITY for a notarizable build)…"
  codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (codesign skipped)"
fi

echo "▸ Zipping…"
ZIP="$DIST/$APP_NAME-$VERSION.zip"
rm -f "$ZIP"
( cd "$DIST" && ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$APP_NAME-$VERSION.zip" )

# Notarize + staple when a notary keychain profile is provided (set up once via
# `xcrun notarytool store-credentials NetLights-notary --apple-id … --team-id … --password …`).
if [ -n "${SIGN_IDENTITY:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "▸ Notarizing (this can take a few minutes)…"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "▸ Stapling…"
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ( cd "$DIST" && ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$APP_NAME-$VERSION.zip" )
  echo "  (stapled; re-zipped)"
fi

echo "✓ Done:"
echo "   $APP"
echo "   $ZIP"
