#!/bin/sh
# Sets up a Mac to build and run Korpora from a checkout: builds pando (the search engine) and
# generates the Xcode project. Run from anywhere inside the checkout.
#
# Prerequisites this does NOT install: Xcode and its command line tools (`xcode-select --install`),
# and xcodegen (`brew install xcodegen`). cmake and ninja are taken from a private venv if missing.
set -e

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

command -v xcodegen >/dev/null || { echo "error: xcodegen not found (brew install xcodegen)." >&2; exit 1; }

echo "==> Building pando (into ~/Developer/pando-work, outside this checkout)"
"$ROOT/scripts/pando-spike.sh" build

echo "==> Generating the Xcode project"
(cd "$ROOT/Korpora" && xcodegen generate)

cat <<MSG

Done. Next:
  scripts/pando-spike.sh sample     # index pando's built-in sample corpus
  scripts/pando-spike.sh test       # run the engine and app tests
  open Korpora/Korpora.xcodeproj    # run the app (the scheme points at the pando build)
MSG
