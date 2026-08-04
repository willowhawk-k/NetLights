#!/bin/sh
# `netlights` — run the NetLights CLI from whichever NetLights.app is installed.
#
# Installed by the `netlights-cli` formula, for people who keep the Mac App Store
# build (which Homebrew can't manage) but still want `netlights tui` on their PATH.
# Users of the `netlights` CASK don't need this: that cask symlinks the binary directly.
#
# It must EXEC the binary in place rather than copy it: the executable resolves
# `Bundle.main` to its enclosing .app, and the bundle's Info.plist is what carries the
# Bluetooth/location usage strings and the code-signing identity. A copy outside the
# bundle loses all of that and crashes the moment the collector touches Bluetooth.
set -u

for app in \
    "/Applications/NetLights.app" \
    "$HOME/Applications/NetLights.app" \
    "/Applications/Utilities/NetLights.app"
do
    if [ -x "$app/Contents/MacOS/NetLights" ]; then
        exec "$app/Contents/MacOS/NetLights" "$@"
    fi
done

cat >&2 <<'EOM'
netlights: couldn't find NetLights.app.

Looked in:
  /Applications/NetLights.app
  ~/Applications/NetLights.app
  /Applications/Utilities/NetLights.app

Install it with either:
  brew install --cask netlights      # the Developer-ID build (adds `netlights serve`)
  or the Mac App Store               # then re-run this command

If NetLights.app lives somewhere else, run its binary directly:
  /path/to/NetLights.app/Contents/MacOS/NetLights --help
EOM
exit 1
