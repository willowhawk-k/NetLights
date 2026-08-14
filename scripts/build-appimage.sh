#!/usr/bin/env bash
#
# Builds the AppImage from the release tarball.
#
# Usage:  ./scripts/build-appimage.sh [aarch64|x86_64]    (no arg = both)
# Output: dist/linux/NetLights-<version>-<arch>.AppImage  (+ .sha256)
#
# There is no appimagetool for macOS — it is itself a Linux AppImage. It is not needed:
# a type-2 AppImage is just the AppImage runtime (a small ELF that mounts the rest of
# itself) with a SquashFS image concatenated onto the end. mksquashfs plus `cat` is the
# whole of what appimagetool does for our case, and doing it explicitly means the build
# runs on the Mac like every other artifact rather than needing the VM in the loop.
#
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

command -v mksquashfs >/dev/null 2>&1 || {
    echo "✗ mksquashfs not found — brew install squashfs (macOS) / apt-get install squashfs-tools (Linux)" >&2
    exit 1
}

XCCONFIG="Version.xcconfig"
VERSION="$(awk -F= '/^MARKETING_VERSION[ \t]*=/ {sub(/^[^=]*=[ \t]*/,""); sub(/[ \t]+$/,""); print; exit}' "$XCCONFIG")"
[ -n "$VERSION" ] || {
    echo "✗ couldn't read MARKETING_VERSION from $XCCONFIG" >&2
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
RUNTIME_DIR="$DIST/.runtime"
# Pinned hashes live in git; the downloaded runtime is checked against them every build.
# The pin is what makes the download safe to automate — see docs/BUILDING.md.
PINS="packaging/appimage-runtime.sha256"
RUNTIME_BASE="https://github.com/AppImage/type2-runtime/releases/download/continuous"

# Reproducibility, same rationale and same knob as build-linux.sh.
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 0)}"

mkdir -p "$RUNTIME_DIR"

echo "▸ NetLights $VERSION — AppImages"

for ARCH in $ARCHES; do
    NAME="netlights-$VERSION-$ARCH"
    TARBALL="$DIST/$NAME.tar.gz"
    [ -f "$TARBALL" ] || {
        echo "✗ [$ARCH] $TARBALL not found — run ./scripts/build-linux.sh $ARCH first" >&2
        exit 1
    }

    # ── Runtime ───────────────────────────────────────────────────────────────────────
    RUNTIME="$RUNTIME_DIR/runtime-$ARCH"
    if [ ! -f "$RUNTIME" ]; then
        echo "▸ [$ARCH] fetching AppImage runtime…"
        curl -fsSL -o "$RUNTIME" "$RUNTIME_BASE/runtime-$ARCH"
    fi

    # Verify against the pin on EVERY build, downloaded fresh or cached. A cached runtime
    # is not automatically trustworthy — it is a file on disk that something else could
    # have replaced.
    [ -f "$PINS" ] || {
        echo "✗ $PINS missing — cannot verify the runtime" >&2
        exit 1
    }
    EXPECTED="$(awk -v a="runtime-$ARCH" '$2 == a {print $1; exit}' "$PINS")"
    [ -n "$EXPECTED" ] || {
        echo "✗ no pinned hash for runtime-$ARCH in $PINS" >&2
        exit 1
    }
    ACTUAL="$(nl_sha256 "$RUNTIME" | cut -d' ' -f1)"
    if [ "$ACTUAL" != "$EXPECTED" ]; then
        echo "✗ [$ARCH] AppImage runtime hash mismatch — REFUSING to build" >&2
        echo "    expected $EXPECTED" >&2
        echo "    actual   $ACTUAL" >&2
        echo "  Either upstream republished the continuous build, or this file was tampered" >&2
        echo "  with. Verify deliberately, then update $PINS." >&2
        exit 1
    fi

    # ── AppDir ────────────────────────────────────────────────────────────────────────
    APPDIR="$DIST/.appdir-$ARCH"
    case "$APPDIR" in
    dist/linux/.appdir-*) ;;
    *)
        echo "✗ refusing to remove unexpected path '$APPDIR'" >&2
        exit 1
        ;;
    esac
    rm -rf "${APPDIR:?}"
    mkdir -p "$APPDIR"

    WORK="$DIST/.ai-$ARCH"
    case "$WORK" in
    dist/linux/.ai-*) ;;
    *)
        echo "✗ refusing to remove unexpected path '$WORK'" >&2
        exit 1
        ;;
    esac
    rm -rf "${WORK:?}"
    mkdir -p "$WORK"
    tar -xzf "$TARBALL" -C "$WORK"
    STAGE="$WORK/$NAME"

    # usr/ mirrors the tarball's prefix, so the AppImage carries the same tree as the
    # packages rather than a bespoke one.
    mkdir -p "$APPDIR/usr"
    cp -R "$STAGE/bin" "$APPDIR/usr/bin"
    cp -R "$STAGE/share" "$APPDIR/usr/share"

    # The spec wants the desktop entry and the icon at the AppDir ROOT, and a .DirIcon for
    # file managers. Missing any of these gives an AppImage that runs but integrates badly.
    cp "$STAGE/share/applications/netlights.desktop" "$APPDIR/netlights.desktop"
    cp "$STAGE/share/icons/hicolor/256x256/apps/netlights.png" "$APPDIR/netlights.png"
    cp "$APPDIR/netlights.png" "$APPDIR/.DirIcon"

    # AppRun: what actually executes when the AppImage is run.
    #
    # The bare `netlights` default is `serve` WITHOUT opening a browser, which as a
    # double-click experience looks like nothing happening. So no-args means
    # `serve --open` here, matching the .desktop; explicit arguments pass straight
    # through so `./NetLights.AppImage tui` still works.
    cat >"$APPDIR/AppRun" <<'APPRUN'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
if [ $# -eq 0 ]; then
    exec "$HERE/usr/bin/netlights" serve --open
fi
exec "$HERE/usr/bin/netlights" "$@"
APPRUN
    chmod 755 "$APPDIR/AppRun"

    # ── SquashFS + runtime ────────────────────────────────────────────────────────────
    SQUASH="$WORK/image.squashfs"
    # gzip, not zstd: the AppImage cannot be executed anywhere on this machine, so the
    # compressor is chosen for the broadest runtime compatibility rather than for size.
    # Revisit once an AppImage has actually been run on Linux.
    # -all-root so the image does not carry this Mac's uid/gid; -mkfs-time/-all-time pin
    # the timestamps so the AppImage is reproducible like the tarball.
    # -no-xattrs: building on macOS otherwise drags com.apple.provenance and friends into
    # a Linux filesystem image. mksquashfs warns and skips them, but they are meaningless
    # on the target and they vary between files, which would also break reproducibility.
    mksquashfs "$APPDIR" "$SQUASH" \
        -comp gzip -b 128K -noappend -no-progress \
        -all-root -no-xattrs \
        -mkfs-time "$SOURCE_DATE_EPOCH" -all-time "$SOURCE_DATE_EPOCH" \
        >/dev/null

    APPIMAGE="$DIST/NetLights-$VERSION-$ARCH.AppImage"
    cat "$RUNTIME" "$SQUASH" >"$APPIMAGE"
    chmod 755 "$APPIMAGE"
    (cd "$DIST" && nl_sha256 "$(basename "$APPIMAGE")" >"$(basename "$APPIMAGE").sha256")

    # Verify the finished artifact, not the inputs. Starting with an ELF header only proves
    # the runtime is at the front; reading the SquashFS back out AT THE RUNTIME'S OFFSET
    # proves the concatenation actually produced a mountable AppImage — which is the only
    # thing that matters and the only part that can silently go wrong.
    file "$APPIMAGE" | grep -q "ELF" || {
        echo "✗ [$ARCH] result is not an ELF — concatenation went wrong" >&2
        exit 1
    }
    OFFSET="$(wc -c <"$RUNTIME" | tr -d ' ')"
    LISTING="$(unsquashfs -o "$OFFSET" -l "$APPIMAGE" 2>/dev/null || true)"
    for REQUIRED in squashfs-root/AppRun squashfs-root/netlights.desktop \
        squashfs-root/.DirIcon squashfs-root/usr/bin/netlights; do
        printf '%s\n' "$LISTING" | grep -qx "$REQUIRED" || {
            echo "✗ [$ARCH] $REQUIRED missing from the AppImage payload" >&2
            exit 1
        }
    done

    rm -rf "${APPDIR:?}" "${WORK:?}"
    echo "  ✓ $APPIMAGE  ($(($(wc -c <"$APPIMAGE" | tr -d ' ') / 1048576)) MB)"
done

echo
echo "✓ Done:"
ls -1 "$DIST"/*.AppImage "$DIST"/*.AppImage.sha256 2>/dev/null | sed 's/^/   /'
