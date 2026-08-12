#!/bin/sh
#
# Refresh the desktop and icon caches so NetLights appears in the menu without a re-login.
#
# Everything here is best-effort. A headless server has none of these tools, and a package
# that failed to install because a cache refresher was missing would be a far worse bug
# than a menu entry appearing a little late — hence the guards and the unconditional exit 0.
set -e

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications 2>/dev/null || true
fi

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -qtf /usr/share/icons/hicolor 2>/dev/null || true
fi

exit 0
