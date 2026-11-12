#!/bin/bash
# Builds abseil and RE2 from pinned tags as static, position-independent libraries into a private
# prefix, for pando's regular expressions (pando built without RE2 reads patterns as bytes: `.` is one
# byte, `[無非毋]` a set of bytes - every non-ASCII regex is wrong; with RE2, patterns are UTF-8 text and
# `\p{Han}` works). Used by build-release-deps.sh (the shipped app) and pando-spike.sh (the dev build),
# so both get the same engine. Nothing is installed system-wide; Homebrew's copies (dynamic, built for
# the newest macOS) are never looked at.
#
# Usage: scripts/build-re2.sh WORKDIR PREFIX [FLOOR] [ARCH]
#   WORKDIR  where sources and build trees go (abseil-src, re2-src, ...)
#   PREFIX   where the static libraries and headers are installed; cmake finds them with CMAKE_PREFIX_PATH
#   FLOOR    macOS deployment target (default 15.0), ARCH (default arm64)
# Needs cmake and ninja on PATH. ABSEIL_REF and RE2_REF override the pinned tags.
set -euo pipefail

WORK="${1:?usage: build-re2.sh WORKDIR PREFIX [FLOOR] [ARCH]}"
PREFIX="${2:?usage: build-re2.sh WORKDIR PREFIX [FLOOR] [ARCH]}"
FLOOR="${3:-15.0}"
ARCH="${4:-arm64}"
ABSEIL_REF="${ABSEIL_REF:-20260817.0}"   # abseil-cpp tag, which RE2 needs
RE2_REF="${RE2_REF:-2025-11-05}"         # RE2 tag
NCPU="$(sysctl -n hw.ncpu)"

die() { echo "ERROR: $*" >&2; exit 1; }
mkdir -p "$WORK"

# Up to date already: the same tags, the same floor.
STAMP="$PREFIX/re2-built-with.txt"
WANT="abseil $ABSEIL_REF re2 $RE2_REF floor $FLOOR arch $ARCH"
if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT" ] && [ -f "$PREFIX/lib/libre2.a" ]; then
    echo "==> RE2 $RE2_REF with abseil $ABSEIL_REF is already built in $PREFIX"
    exit 0
fi

fetch_tag() {   # name url tag
    local dir="$WORK/$1-src"
    if [ -d "$dir/.git" ]; then git -C "$dir" fetch -q --tags origin; else git clone -q "$2" "$dir"; fi
    git -C "$dir" checkout -q "$3"
}

build_static() {   # name extra cmake args...
    local name="$1"; shift
    rm -rf "$WORK/$name-build"
    cmake -S "$WORK/$name-src" -B "$WORK/$name-build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
        -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_CXX_STANDARD=17 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$FLOOR" -DCMAKE_OSX_ARCHITECTURES="$ARCH" "$@" > "$WORK/$name-cmake.log" 2>&1 \
        || { tail -20 "$WORK/$name-cmake.log" >&2; die "$name: cmake failed - log: $WORK/$name-cmake.log"; }
    cmake --build "$WORK/$name-build" -j "$NCPU" > "$WORK/$name-build.log" 2>&1 \
        || { tail -20 "$WORK/$name-build.log" >&2; die "$name: build failed - log: $WORK/$name-build.log"; }
    cmake --install "$WORK/$name-build" > /dev/null 2>&1 || die "$name: install failed"
}

echo "==> abseil $ABSEIL_REF and RE2 $RE2_REF (static, deployment target $FLOOR, $ARCH)"
rm -rf "$PREFIX"
fetch_tag abseil https://github.com/abseil/abseil-cpp.git "$ABSEIL_REF"
build_static abseil -DABSL_PROPAGATE_CXX_STD=ON -DABSL_BUILD_TESTING=OFF -DABSL_ENABLE_INSTALL=ON
fetch_tag re2 https://github.com/google/re2.git "$RE2_REF"
build_static re2 -DRE2_BUILD_TESTING=OFF
[ -f "$PREFIX/lib/libre2.a" ] || die "libre2.a missing after the build"
echo "$WANT" > "$STAMP"
