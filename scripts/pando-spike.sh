#!/bin/bash
# Builds pando, indexes test corpora and runs Korpora's tests against it.
# Everything lands in one work directory (default ~/Developer/pando-work), outside this repo.
#
#   scripts/pando-spike.sh build      # clone/update ufal/pando, build pando + libpando
#   scripts/pando-spike.sh sample     # index pando's built-in test/data/sample.conllu
#   scripts/pando-spike.sh ud         # download the full UD release and index it (large: GBs, takes a while)
#   scripts/pando-spike.sh test       # run the engine and app tests with the pando library loaded
#   scripts/pando-spike.sh all        # build, sample, test
#   scripts/pando-spike.sh query IDX 'CQL'   # run a query with the pando CLI
#   scripts/pando-spike.sh status     # what is new in pando since the commit releases are built with (scripts/PANDO_REF)
#   scripts/pando-spike.sh pin [REF]  # make REF (default: pando's newest commit) the one releases are built with
#
# Needs git, Python 3, Xcode. cmake and ninja are taken from a private venv in the work
# directory if they aren't installed (nothing is installed system-wide). Regex runs without
# RE2 (slow on big lexicons); pass PANDO_USE_RE2=ON if you have it (brew install re2).
set -euo pipefail

WORK="${PANDO_WORK:-$HOME/Developer/pando-work}"
SRC="$WORK/pando"
BUILD="$SRC/build"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$WORK"

tools() {
  if ! command -v cmake >/dev/null || ! command -v ninja >/dev/null; then
    [ -x "$WORK/venv/bin/cmake" ] || { python3 -m venv "$WORK/venv"; "$WORK/venv/bin/pip" install -q cmake ninja; }
    export PATH="$WORK/venv/bin:$PATH"
  fi
}

build() {
  tools
  if [ -d "$SRC/.git" ]; then git -C "$SRC" fetch -q && git -C "$SRC" checkout -q origin/main
  else git clone -q https://github.com/ufal/pando.git "$SRC" && git -C "$SRC" checkout -q origin/main; fi
  echo "pando $(git -C "$SRC" describe --tags 2>/dev/null || git -C "$SRC" rev-parse --short HEAD)"
  # Deployment target 15.0: what Korpora supports; the default would be this Mac's own macOS.
  cmake -S "$SRC" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release -DPANDO_BUILD_SHARED=ON \
    -DPANDO_USE_RE2="${PANDO_USE_RE2:-OFF}" -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 >"$WORK/cmake.log"
  cmake --build "$BUILD" >"$WORK/build.log"
  ls "$BUILD"/pando "$BUILD"/pando-index "$BUILD"/libpando.dylib
}

pinned() { grep -v '^#' "$ROOT/scripts/PANDO_REF" | grep -v '^$' | head -1; }

fetch_source() {
  if [ -d "$SRC/.git" ]; then git -C "$SRC" fetch -q --tags origin
  else git clone -q https://github.com/ufal/pando.git "$SRC"; fi
}

status() {
  fetch_source
  local pin latest behind
  pin="$(pinned)"
  latest="$(git -C "$SRC" rev-parse --short origin/main)"
  behind="$(git -C "$SRC" rev-list --count "$pin..origin/main")"
  echo "releases are built with pando $pin ($(git -C "$SRC" log -1 --format=%cs "$pin"))"
  echo "pando's newest commit:   $latest ($(git -C "$SRC" log -1 --format=%cs origin/main)), tags: $(git -C "$SRC" tag --sort=-creatordate | head -3 | tr '\n' ' ')"
  if [ "$behind" = 0 ]; then echo "up to date."; return; fi
  echo "$behind new commit(s) since the pin:"
  git -C "$SRC" log --format='  %h %cs %s' "$pin..origin/main" | head -40
  echo "files that touch the C API: $(git -C "$SRC" diff --stat "$pin" origin/main -- src/api/pando_ffi.h src/api/pando_ffi.cpp | tail -1)"
  echo "to take them: $0 pin  (then test, and build the release)"
}

pin() {
  fetch_source
  local ref
  ref="$(git -C "$SRC" rev-parse --short "${1:-origin/main}")"
  { grep '^#' "$ROOT/scripts/PANDO_REF"; echo "$ref"; } > "$ROOT/scripts/PANDO_REF.new"
  mv "$ROOT/scripts/PANDO_REF.new" "$ROOT/scripts/PANDO_REF"
  echo "releases will be built with pando $ref ($(git -C "$SRC" log -1 --format=%s "$ref"))"
  echo "commit scripts/PANDO_REF, and fix the comment in it if the version changed."
}

sample() {
  rm -rf "$WORK/sample-idx"
  "$BUILD/pando-index" "$SRC/test/data/sample.conllu" "$WORK/sample-idx" >/dev/null
  echo "index: $WORK/sample-idx"
  "$BUILD/pando" "$WORK/sample-idx" '[upos="VERB"]' --limit 3
  "$BUILD/pando" "$WORK/sample-idx" '[upos="VERB"]' --count-only
}

ud() {
  # Latest UD release from LINDAT into $WORK/ud-data, indexed to $WORK/ud-idx (see pando's wiki/Sample-Corpora.md).
  PANDO_UD_DATA="$WORK/ud-data" python3 "$SRC/scripts/build_ud_corpus.py" \
    --pando-index "$BUILD/pando-index" --output-index "$WORK/ud-idx"
  "$BUILD/pando" "$WORK/ud-idx" '[upos="VERB"]' --count-only --timing
}

tests() {
  export KORPORA_PANDO_LIB="$BUILD/libpando.dylib"
  [ -f "$KORPORA_PANDO_LIB" ] || { echo "no $KORPORA_PANDO_LIB: run '$0 build' first" >&2; exit 1; }
  [ -d "$WORK/sample-idx" ] && export KORPORA_PANDO_SAMPLE="$WORK/sample-idx"
  [ -d "$WORK/ud-idx" ] && export KORPORA_PANDO_UD="$WORK/ud-idx"
  echo "== KorporaEngine tests"
  (cd "$ROOT/KorporaEngine" && swift test 2>&1 | grep -E "error:|Executed .* tests" | tail -2)
  echo "== App (document tests against pando)"
  (cd "$ROOT/Korpora" && TEST_RUNNER_KORPORA_PANDO_LIB="$KORPORA_PANDO_LIB" \
     TEST_RUNNER_KORPORA_PANDO_SAMPLE="${KORPORA_PANDO_SAMPLE:-}" TEST_RUNNER_KORPORA_PANDO_UD="${KORPORA_PANDO_UD:-}" \
     xcodebuild -project Korpora.xcodeproj -scheme Korpora -configuration Debug test 2>&1 | grep -E "error:|✘|Test run with|TEST (SUCC|FAIL)" | grep -v "Connection\]")
}

case "${1:-}" in
  build) build ;;
  sample) sample ;;
  ud) ud ;;
  test) tests ;;
  all) build; sample; tests ;;
  status) status ;;
  pin) shift; pin "$@" ;;
  query) shift; "$BUILD/pando" "$@" ;;
  *) sed -n 2,16p "$0"; exit 1 ;;
esac
