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
# Distinct from the Mac App Store build's id (com.willowhawk.NetLights) — the extra
# ".gh" segment (not just a case difference) lets both installs coexist on one Mac
# without Launch Services conflating them. Display name stays "NetLights".
BUNDLE_ID="com.willowhawk.NetLights.gh"

# Version: single source of truth, shared with the Mac App Store Xcode target.
XCCONFIG="Version.xcconfig"
xcval() { awk -F= -v k="$1" '$0 ~ "^"k"[ \t]*=" {sub(/^[^=]*=[ \t]*/,""); sub(/[ \t]+$/,""); print; exit}' "$XCCONFIG"; }
VERSION="$(xcval MARKETING_VERSION)"
BUILD="$(xcval CURRENT_PROJECT_VERSION)"
RELEASE_DATE="$(xcval NL_RELEASE_DATE)"

# Version.swift carries a hand-maintained copy of MARKETING_VERSION, because the Linux and
# `swift run` builds have no Info.plist to read and a SwiftPM manifest is evaluated on the
# host, so it cannot pull the value from this xcconfig at build time. That duplication is
# exactly the kind that drifts silently — the Linux binary would keep reporting the previous
# release forever. Fail the build rather than ship a mislabelled binary.
SWIFT_VERSION_FILE="Sources/NetLightsCore/Version.swift"
SWIFT_VERSION="$(sed -n 's/^public let netLightsVersion = "\(.*\)"$/\1/p' "$SWIFT_VERSION_FILE")"
if [ "$SWIFT_VERSION" != "$VERSION" ]; then
    echo "error: version drift" >&2
    echo "  $XCCONFIG says       $VERSION" >&2
    echo "  $SWIFT_VERSION_FILE says $SWIFT_VERSION" >&2
    echo "  Update netLightsVersion in $SWIFT_VERSION_FILE to match, then rebuild." >&2
    exit 1
fi
[ -n "$VERSION" ] && [ -n "$BUILD" ] || { echo "✗ couldn't read version from $XCCONFIG"; exit 1; }
echo "▸ Version $VERSION ($BUILD) — from $XCCONFIG"

DIST="dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "▸ Building release binary…"
swift build -c release

# Ask SwiftPM where it actually put the binary. `.build/release` is a SYMLINK that points
# at whichever configuration built last — so after a Linux cross-build it aims at an ELF
# binary, and packaging it would produce a broken .app that still signs and notarizes.
BINDIR="$(swift build -c release --show-bin-path)"
BIN="$BINDIR/$APP_NAME"
[ -f "$BIN" ] || { echo "✗ binary not found at $BIN"; exit 1; }
file "$BIN" | grep -q "Mach-O" || { echo "✗ $BIN is not a Mach-O binary — wrong build?"; exit 1; }

echo "▸ Assembling $APP …"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$BIN" "$MACOS/$APP_NAME"

# The CLI shim ships INSIDE the bundle so Homebrew's cask can symlink to it. A symlink
# straight to Contents/MacOS/NetLights does not let the executable resolve Bundle.main back
# to the .app: version reporting falls back to "dev" and the LaunchServices hand-off never
# fires. Going through this shim (which execs its own bundle's binary) fixes both.
cp scripts/netlights-shim.sh "$RES/netlights"
chmod +x "$RES/netlights"

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
    <key>NLReleaseDate</key>           <string>$RELEASE_DATE</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>NetLights uses your location only to read the current Wi-Fi network name (SSID), which macOS protects behind location access. No location coordinates are read, stored, or shared.</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>NetLights uses Bluetooth only to list your already-connected Bluetooth devices (name, type, and battery where reported) in the graph. It never scans for, pairs with, or connects to anything.</string>
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
