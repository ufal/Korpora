#!/bin/bash
# Builds what a shippable Korpora.app needs that the dev setup does not provide: pando
# (`libpando.dylib`, the search engine the app loads at run time, and `pando-index`, which builds
# corpora), compiled at the release deployment floor ($FLOOR) from a pinned ref. Nothing from the
# dev build in ~/Developer/pando-work is reused, so the release never depends on a local checkout.
#
# pando has no third-party runtime dependency beyond the system C++ runtime (regular expressions run
# on the standard library: RE2 is left off, which makes regex queries over a very large vocabulary
# slower than a build with it; see docs/pando-analysis.md).
#
# Usage:
#   scripts/build-release-deps.sh              # pando as pinned in scripts/PANDO_REF, FLOOR=15.0 ARCH=arm64
#   PANDO_REF=<tag-or-commit> scripts/build-release-deps.sh   # for one build, without changing the pin
#
# On success it prints the variable the app build needs (make-release.sh sets it itself).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
FLOOR="${FLOOR:-15.0}"
ARCH="${ARCH:-arm64}"
# The pinned pando is in scripts/PANDO_REF (first line that isn't a comment).
PANDO_REF="${PANDO_REF:-$(grep -v '^#' "$SCRIPT_DIR/PANDO_REF" | grep -v '^$' | head -1)}"
[ -n "$PANDO_REF" ] || { echo "ERROR: no pando ref in $SCRIPT_DIR/PANDO_REF" >&2; exit 1; }
PANDO_URL="${PANDO_URL:-https://github.com/ufal/pando.git}"
DEP="$ROOT/release-deps"
SRC="$DEP/pando-src"
BUILD="$DEP/pando/build"
NCPU="$(sysctl -n hw.ncpu)"

die() { echo "ERROR: $*" >&2; exit 1; }

# cmake and ninja: installed ones, else a private venv under release-deps (nothing system-wide).
mkdir -p "$DEP"
if ! command -v cmake >/dev/null || ! command -v ninja >/dev/null; then
    [ -x "$DEP/venv/bin/cmake" ] || { python3 -m venv "$DEP/venv"; "$DEP/venv/bin/pip" install -q cmake ninja; }
    export PATH="$DEP/venv/bin:$PATH"
fi

if [ -d "$SRC/.git" ]; then
    git -C "$SRC" fetch -q --tags origin
else
    git clone -q "$PANDO_URL" "$SRC"
fi
git -C "$SRC" checkout -q "$PANDO_REF"
COMMIT="$(git -C "$SRC" rev-parse --short HEAD)"
echo "==> pando $PANDO_REF ($COMMIT), deployment target $FLOOR, $ARCH"

rm -rf "$BUILD"
cmake -S "$SRC" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release -DPANDO_BUILD_SHARED=ON -DPANDO_USE_RE2=OFF \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$FLOOR" -DCMAKE_OSX_ARCHITECTURES="$ARCH" > "$DEP/pando-cmake.log" 2>&1 \
    || { tail -20 "$DEP/pando-cmake.log" >&2; die "cmake failed - log: $DEP/pando-cmake.log"; }
cmake --build "$BUILD" -j "$NCPU" > "$DEP/pando-build.log" 2>&1 \
    || { tail -20 "$DEP/pando-build.log" >&2; die "build failed - log: $DEP/pando-build.log"; }

# What was built must be what the app expects.
[ -x "$BUILD/pando-index" ] || die "pando-index missing after the build"
[ -f "$BUILD/libpando.dylib" ] || die "libpando.dylib missing after the build"
for symbol in pando_open pando_last_error pando_cancel pando_query pando_run pando_info pando_free_string pando_close; do
    nm -gU "$BUILD/libpando.dylib" | grep -q "_$symbol\$" || die "libpando.dylib lacks $symbol"
done
for binary in "$BUILD/pando-index" "$BUILD/libpando.dylib"; do
    minos="$(vtool -show-build "$binary" | awk '/minos/ {print $2}' | head -1)"
    [ "$minos" = "$FLOOR" ] || die "$(basename "$binary") has minos $minos, expected $FLOOR"
    if otool -L "$binary" | grep -E "/opt/homebrew|/usr/local" >/dev/null; then
        die "$(basename "$binary") links a library outside the system"
    fi
done
echo "$COMMIT" > "$DEP/pando/.built-from"
touch "$DEP/pando/build-ok"

echo
echo "pando is built. make-release.sh uses it; to bundle it by hand, export:"
echo "  PANDO_BUILD_DIR=$BUILD"
