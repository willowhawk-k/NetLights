#!/usr/bin/env bash
#
# Builds the fully-static Linux binaries and wraps each in a distributable tarball.
#
# Usage:  ./scripts/build-linux.sh [aarch64|x86_64]      (no arg = both)
# Output: dist/linux/netlights-<version>-<arch>.tar.gz   (+ .sha256)
#
# The tarball is the base artifact for every other Linux format — nfpm's .deb/.rpm, the
# AppImage and the CI matrix all wrap this same tree, so its layout deliberately mirrors
# an FHS prefix (bin/, share/) and a package can map it path-for-path.
#
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

# ── Version ───────────────────────────────────────────────────────────────────────────
# Same single source of truth as the macOS build, and the same drift guard: Version.swift
# carries the hand-maintained copy that ends up compiled into THIS binary (no Info.plist on
# Linux), so if it disagrees with the xcconfig the tarball would ship mislabelled.
XCCONFIG="Version.xcconfig"
xcval() { awk -F= -v k="$1" '$0 ~ "^"k"[ \t]*=" {sub(/^[^=]*=[ \t]*/,""); sub(/[ \t]+$/,""); print; exit}' "$XCCONFIG"; }
VERSION="$(xcval MARKETING_VERSION)"

SWIFT_VERSION_FILE="Sources/NetLightsCore/Version.swift"
SWIFT_VERSION="$(sed -n 's/^public let netLightsVersion = "\(.*\)"$/\1/p' "$SWIFT_VERSION_FILE")"
if [ "$SWIFT_VERSION" != "$VERSION" ]; then
    echo "error: version drift" >&2
    echo "  $XCCONFIG says       $VERSION" >&2
    echo "  $SWIFT_VERSION_FILE says $SWIFT_VERSION" >&2
    echo "  Update netLightsVersion in $SWIFT_VERSION_FILE to match, then rebuild." >&2
    exit 1
fi
[ -n "$VERSION" ] || {
    echo "✗ couldn't read version from $XCCONFIG" >&2
    exit 1
}

# ── Toolchain ─────────────────────────────────────────────────────────────────────────
SWIFTLY_BIN="${SWIFTLY_BIN:-$HOME/.swiftly/bin}"

# How to invoke swift, in order of preference.
#
# The swiftly indirection exists for ONE reason: on a Mac, plain `swift` is Xcode's, and
# the Xcode toolchain cannot consume the musl SDK (module-format mismatch). So where
# swiftly is present it wins. In the official Swift container there is no swiftly and
# `swift` already IS the swift.org toolchain, so plain swift is correct there — hard-
# requiring swiftly made the script macOS-only for no reason.
#
# $SWIFT overrides both, for anyone with a toolchain somewhere else entirely.
if [ -n "${SWIFT:-}" ]; then
    SWIFT_CMD=("$SWIFT")
elif [ -x "$SWIFTLY_BIN/swiftly" ]; then
    SWIFT_CMD=("$SWIFTLY_BIN/swiftly" run swift)
elif command -v swiftly >/dev/null 2>&1; then
    SWIFT_CMD=("$(command -v swiftly)" run swift)
elif command -v swift >/dev/null 2>&1; then
    SWIFT_CMD=("$(command -v swift)")
else
    echo "✗ no swift found (tried \$SWIFT, swiftly, PATH)" >&2
    echo "  See docs/BUILDING.md#linux" >&2
    exit 1
fi
echo "▸ swift: ${SWIFT_CMD[*]}"

# llvm-objcopy specifically, not strip(1) or GNU objcopy: macOS strip cannot read ELF at
# all, and GNU objcopy is typically built for a single target, so it cannot strip the
# other architecture's binary. llvm-objcopy is multi-target on both hosts.
OBJCOPY="${OBJCOPY:-}"
if [ -z "$OBJCOPY" ]; then
    if [ -x "$SWIFTLY_BIN/llvm-objcopy" ]; then
        OBJCOPY="$SWIFTLY_BIN/llvm-objcopy"
    elif command -v llvm-objcopy >/dev/null 2>&1; then
        OBJCOPY="$(command -v llvm-objcopy)"
    fi
fi
[ -n "$OBJCOPY" ] && [ -x "$OBJCOPY" ] || {
    echo "✗ llvm-objcopy not found (tried \$OBJCOPY, $SWIFTLY_BIN, PATH)" >&2
    exit 1
}

case "${1:-both}" in
aarch64) ARCHES="aarch64" ;;
x86_64) ARCHES="x86_64" ;;
both) ARCHES="aarch64 x86_64" ;;
*)
    echo "✗ unknown arch '${1}' — use aarch64, x86_64, or nothing for both" >&2
    exit 1
    ;;
esac

DIST="dist/linux"
mkdir -p "$DIST"

# Reproducibility: same commit in, same bytes out, so a CI artifact and a local build can be
# compared by hash and anyone can check the download against the source. Three things
# otherwise leak the wall clock into the tarball — file mtimes, the uid/gid/mode of whoever
# built it, and gzip's own header timestamp. This pins the first (SOURCE_DATE_EPOCH, the
# cross-ecosystem convention, defaulting to the commit date); --numeric-owner and `gzip -n`
# below handle the other two.
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"
STAMP="$(nl_touch_stamp "$SOURCE_DATE_EPOCH")"

echo "▸ NetLights $VERSION — static Linux tarballs"

for ARCH in $ARCHES; do
    SDK="$ARCH-swift-linux-musl"
    echo
    echo "▸ [$ARCH] building…"
    NETLIGHTS_LINUX=1 "${SWIFT_CMD[@]}" build -c release --swift-sdk "$SDK" >/dev/null

    # Ask SwiftPM where it put the binary rather than guessing: .build/release is a symlink
    # that follows whichever configuration built last, so a preceding macOS build would
    # otherwise get packaged as a Linux artifact.
    BINDIR="$(NETLIGHTS_LINUX=1 "${SWIFT_CMD[@]}" build -c release --swift-sdk "$SDK" --show-bin-path)"
    BIN="$BINDIR/netlights"
    [ -f "$BIN" ] || {
        echo "✗ [$ARCH] binary not found at $BIN" >&2
        exit 1
    }

    # The whole portability premise is that this thing has no shared-library deps. Verify
    # rather than trust: a build that quietly picked up a dynamic dependency would install
    # fine here and fail on the user's distro.
    DESC="$(file "$BIN")"
    case "$DESC" in
    *ELF*) ;;
    *)
        echo "✗ [$ARCH] not an ELF binary: $DESC" >&2
        exit 1
        ;;
    esac
    case "$DESC" in
    *"statically linked"*) ;;
    *)
        echo "✗ [$ARCH] not statically linked — the musl SDK did not take: $DESC" >&2
        exit 1
        ;;
    esac
    case "$ARCH:$DESC" in
    aarch64:*aarch64* | x86_64:*x86-64*) ;;
    *)
        echo "✗ [$ARCH] architecture mismatch: $DESC" >&2
        exit 1
        ;;
    esac

    # ── Stage ─────────────────────────────────────────────────────────────────────────
    NAME="netlights-$VERSION-$ARCH"
    STAGE="$DIST/$NAME"
    # Guarded removal: $STAGE is built from variables, so prove its shape before deleting.
    # ${STAGE:?} additionally aborts if it is ever empty or unset.
    case "$STAGE" in
    dist/linux/netlights-*) ;;
    *)
        echo "✗ refusing to remove unexpected path '$STAGE'" >&2
        exit 1
        ;;
    esac
    rm -rf "${STAGE:?}"
    mkdir -p "$STAGE/bin" \
        "$STAGE/share/applications" \
        "$STAGE/share/doc/netlights" \
        "$STAGE/share/icons/hicolor/128x128/apps" \
        "$STAGE/share/icons/hicolor/256x256/apps" \
        "$STAGE/share/icons/hicolor/512x512/apps"

    # Strip: ~151 MB of unstripped Swift debug info down to ~58 MB. Nothing at runtime
    # needs it, and it is the difference between a plausible download and an absurd one.
    RAW_SIZE="$(wc -c <"$BIN" | tr -d ' ')"
    "$OBJCOPY" --strip-all "$BIN" "$STAGE/bin/netlights"
    chmod 755 "$STAGE/bin/netlights"
    NEW_SIZE="$(wc -c <"$STAGE/bin/netlights" | tr -d ' ')"
    echo "  stripped $((RAW_SIZE / 1048576)) MB → $((NEW_SIZE / 1048576)) MB"

    # ── Desktop integration ───────────────────────────────────────────────────────────
    # Exec uses `serve --open`: this build has no native window yet (see the Part 2 phase
    # in docs/LINUX-PORT.md), so launching from a menu means starting the local server and
    # pointing the browser at it. Note the server keeps running after the browser tab is
    # closed — the native window is what actually fixes that.
    cat >"$STAGE/share/applications/netlights.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Version=1.0
Name=NetLights
GenericName=Network Map
Comment=Live, layered map of your network interfaces
Exec=netlights serve --open
Icon=netlights
Terminal=false
Categories=Network;Monitor;
Keywords=network;interface;route;dns;monitor;traffic;
StartupNotify=true
DESKTOP

    cp assets/AppIcon.appiconset/icon_128x128.png "$STAGE/share/icons/hicolor/128x128/apps/netlights.png"
    cp assets/AppIcon.appiconset/icon_256x256.png "$STAGE/share/icons/hicolor/256x256/apps/netlights.png"
    cp assets/AppIcon.appiconset/icon_512x512.png "$STAGE/share/icons/hicolor/512x512/apps/netlights.png"

    cp README.md LICENSE PRIVACY.md "$STAGE/share/doc/netlights/"
    cp docs/LINUX.md docs/CLI.md "$STAGE/share/doc/netlights/"

    # ── install.sh ────────────────────────────────────────────────────────────────────
    # Copy-only by design. An uninstaller that removed a prefix built from a variable is
    # exactly the footgun worth not shipping; removal is documented instead.
    cat >"$STAGE/install.sh" <<'INSTALL'
#!/bin/sh
#
# Installs NetLights into a prefix. Default /usr/local (needs root); pass another prefix
# to install without it, e.g.  ./install.sh ~/.local
#
set -eu

PREFIX="${1:-/usr/local}"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "Installing NetLights into $PREFIX"
mkdir -p "$PREFIX/bin" "$PREFIX/share"
cp -f "$HERE/bin/netlights" "$PREFIX/bin/netlights"
chmod 755 "$PREFIX/bin/netlights"
cp -R "$HERE/share/." "$PREFIX/share/"

# Refresh the menu/icon caches when the tools exist; harmless when they do not.
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$PREFIX/share/applications" 2>/dev/null || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -qtf "$PREFIX/share/icons/hicolor" 2>/dev/null || true
fi

cat <<EOF

Installed. Try:

    netlights            web UI on http://127.0.0.1:8765
    netlights tui        terminal dashboard
    netlights --help     everything else

To remove it again, delete these:

    $PREFIX/bin/netlights
    $PREFIX/share/applications/netlights.desktop
    $PREFIX/share/doc/netlights
    $PREFIX/share/icons/hicolor/*/apps/netlights.png
EOF
INSTALL
    chmod 755 "$STAGE/install.sh"

    # ── Tarball ───────────────────────────────────────────────────────────────────────
    TARBALL="$DIST/$NAME.tar.gz"
    rm -f "$TARBALL" "$TARBALL.sha256"
    # Pin every mtime to SOURCE_DATE_EPOCH, then archive with fixed ownership and gzip with
    # -n so no header timestamp is recorded. See the SOURCE_DATE_EPOCH note above.
    find "$STAGE" -exec touch -h -t "$STAMP" {} +
    # The two tars spell "force root ownership" differently and each rejects the other's
    # spelling: bsdtar (macOS) takes --uid/--gid, GNU tar takes --owner=/--group=. Written
    # out twice rather than assembled into an array, because bash 3.2 still ships as
    # /bin/bash on macOS and mapfile would be a portability bug of its own.
    if tar --version 2>/dev/null | head -1 | grep -qi "gnu tar"; then
        tar --format=ustar --owner=0 --group=0 --numeric-owner \
            -C "$DIST" -cf - "$NAME" | gzip -9 -n >"$TARBALL"
    else
        tar --format=ustar --uid 0 --gid 0 --numeric-owner \
            -C "$DIST" -cf - "$NAME" | gzip -9 -n >"$TARBALL"
    fi
    (cd "$DIST" && nl_sha256 "$NAME.tar.gz" >"$NAME.tar.gz.sha256")

    # ── Verify the artifact, not the staging tree ─────────────────────────────────────
    VERIFY="$DIST/.verify-$ARCH"
    case "$VERIFY" in
    dist/linux/.verify-*) ;;
    *)
        echo "✗ refusing to remove unexpected path '$VERIFY'" >&2
        exit 1
        ;;
    esac
    rm -rf "${VERIFY:?}"
    mkdir -p "$VERIFY"
    tar -xzf "$TARBALL" -C "$VERIFY"
    [ -x "$VERIFY/$NAME/bin/netlights" ] || {
        echo "✗ [$ARCH] binary missing or not executable in the tarball" >&2
        exit 1
    }
    [ -f "$VERIFY/$NAME/share/applications/netlights.desktop" ] || {
        echo "✗ [$ARCH] .desktop missing from the tarball" >&2
        exit 1
    }
    file "$VERIFY/$NAME/bin/netlights" | grep -q "statically linked" || {
        echo "✗ [$ARCH] extracted binary is not static" >&2
        exit 1
    }
    rm -rf "${VERIFY:?}"

    rm -rf "${STAGE:?}"
    echo "  ✓ $TARBALL  ($(($(wc -c <"$TARBALL" | tr -d ' ') / 1048576)) MB)"
done

echo
echo "✓ Done:"
ls -1 "$DIST"/*.tar.gz "$DIST"/*.sha256 2>/dev/null | sed 's/^/   /'
