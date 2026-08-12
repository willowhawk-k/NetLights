#!/usr/bin/env bash
#
# Builds the .deb and .rpm from the release tarballs, via nfpm.
#
# Usage:  ./scripts/build-packages.sh [aarch64|x86_64]     (no arg = both)
# Output: dist/linux/netlights_<version>_<debarch>.deb
#         dist/linux/netlights-<version>-1.<rpmarch>.rpm
#
# Packages are built by EXTRACTING the release tarball rather than by re-staging from the
# build tree. The bytes users install are then provably the bytes they can download and
# hash — a parallel staging path would be free to drift from the tarball without anything
# noticing.
#
set -euo pipefail

cd "$(dirname "$0")/.."

command -v nfpm >/dev/null 2>&1 || {
    echo "✗ nfpm not found — brew install nfpm" >&2
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

echo "▸ NetLights $VERSION — Linux packages"

for ARCH in $ARCHES; do
    # nfpm speaks Go's architecture names; the tarballs and rpm speak the uname ones.
    case "$ARCH" in
    aarch64) NFPM_ARCH="arm64" ;;
    x86_64) NFPM_ARCH="amd64" ;;
    esac

    NAME="netlights-$VERSION-$ARCH"
    TARBALL="$DIST/$NAME.tar.gz"
    [ -f "$TARBALL" ] || {
        echo "✗ [$ARCH] $TARBALL not found — run ./scripts/build-linux.sh $ARCH first" >&2
        exit 1
    }

    echo
    echo "▸ [$ARCH] unpacking $TARBALL"
    WORK="$DIST/.pkg-$ARCH"
    # Guarded removal: built from variables, so prove the shape first and let ${var:?}
    # abort on an empty value.
    case "$WORK" in
    dist/linux/.pkg-*) ;;
    *)
        echo "✗ refusing to remove unexpected path '$WORK'" >&2
        exit 1
        ;;
    esac
    rm -rf "${WORK:?}"
    mkdir -p "$WORK"
    tar -xzf "$TARBALL" -C "$WORK"

    STAGE="$WORK/$NAME"
    [ -x "$STAGE/bin/netlights" ] || {
        echo "✗ [$ARCH] no executable at $STAGE/bin/netlights" >&2
        exit 1
    }

    # Re-assert staticness here too. This script can be run against a tarball built long
    # ago or fetched from elsewhere, so it cannot assume build-linux.sh just vouched for it.
    file "$STAGE/bin/netlights" | grep -q "statically linked" || {
        echo "✗ [$ARCH] binary in the tarball is not statically linked" >&2
        exit 1
    }

    # Render the template. nfpm's env expansion does not reach contents.src (it emits the
    # literal ${NL_STAGE} and fails the glob), so substitute here instead of depending on
    # it. The rendered file is left beside the extracted tree for the whole run, which
    # makes "what exactly went into this package" answerable by reading one file.
    CONFIG="$WORK/nfpm.yaml"
    sed -e "s|\${NL_VERSION}|$VERSION|g" \
        -e "s|\${NL_NFPM_ARCH}|$NFPM_ARCH|g" \
        -e "s|\${NL_STAGE}|$STAGE|g" \
        packaging/nfpm.yaml.in >"$CONFIG"
    # Fail loudly rather than shipping a package with a literal placeholder inside it.
    if grep -q '\${NL_' "$CONFIG"; then
        echo "✗ [$ARCH] unsubstituted placeholder left in $CONFIG:" >&2
        grep -n '\${NL_' "$CONFIG" >&2
        exit 1
    fi

    for PACKAGER in deb rpm; do
        echo "  building .$PACKAGER…"
        nfpm package --config "$CONFIG" --packager "$PACKAGER" --target "$DIST/"
    done

    rm -rf "${WORK:?}"
done

echo
echo "✓ Done:"
ls -1 "$DIST"/*.deb "$DIST"/*.rpm 2>/dev/null | sed 's/^/   /'
