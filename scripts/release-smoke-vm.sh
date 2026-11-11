#!/bin/bash
# Release smoke test, the scripted half of docs/project-plan.md's "Goal -
# Ship a signed GitHub release" step 6. Runs INSIDE a clean macOS VM at the
# release floor, over SSH, with ~/smoke/ holding Korpora-<version>.dmg,
# smoke.conllu (scripts/smoke/smoke.conllu) and this script.
#
# How it was run for 0.1 (host side, see the plan for details):
#   tart clone ghcr.io/cirruslabs/macos-sequoia-vanilla:latest korpora-smoke-15
#   tart run korpora-smoke-15          # visible window, for the manual part
#   (install an SSH key with the image's admin/admin login, scp ~/smoke over)
#   In the VM, turn Gatekeeper back ON first - the Cirrus image ships with
#   assessments disabled:  sudo spctl --global-enable
#
#   bash ~/smoke/release-smoke-vm.sh install   # Gatekeeper checks + install
#     (or, with the folder shared into the VM by `tart run --dir=smoke:<folder>`:
#      bash "/Volumes/My Shared Files/smoke/release-smoke-vm.sh" install)
#   ... manual: first launch from Finder (expect only the "downloaded from
#       the Internet" prompt), import smoke.conllu via the UI, run a query,
#       check completion, change a setting, quit + relaunch ...
#   bash ~/smoke/release-smoke-vm.sh exec      # bundled pando + relaunch
#
# The install phase must run before anything executes the app: running the
# quarantined binary or its helpers first could clear the first-launch
# prompt the manual step is meant to see.
set -u
PHASE="${1:-install}"
# The folder with the DMG and smoke.conllu: where this script is (a folder shared into the VM, or ~/smoke).
SMOKE_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SMOKE_DIR"
pass=0; fail=0
ok()  { echo "PASS: $*"; pass=$((pass+1)); }
bad() { echo "FAIL: $*"; fail=$((fail+1)); }

if [ "$PHASE" = install ]; then
echo "== Environment"
sw_vers; uname -m
[ -e /opt/homebrew ] && bad "/opt/homebrew exists" || ok "no /opt/homebrew"
command -v brew >/dev/null && bad "brew on PATH" || ok "no brew"
xcode-select -p >/dev/null 2>&1 && echo "note: developer tools present at $(xcode-select -p)" || ok "no developer tools"

echo "== Simulated browser download (quarantine xattr, as Safari sets it)"
mkdir -p "$HOME/Downloads"
DMG_NAME="$(ls Korpora-*.dmg 2>/dev/null | head -1)"
[ -n "$DMG_NAME" ] || { echo "no Korpora-*.dmg in ~/smoke"; exit 1; }
cp "$DMG_NAME" "$HOME/Downloads/"
DMG="$HOME/Downloads/$DMG_NAME"
xattr -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;$(uuidgen)" "$DMG"
spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 | tee /tmp/s1
grep -q "source=Notarized Developer ID" /tmp/s1 && ok "DMG: Notarized Developer ID" || bad "DMG Gatekeeper"
xcrun stapler validate "$DMG" >/dev/null 2>&1 && ok "DMG ticket stapled" || echo "note: stapler needs dev tools; skipped"

echo "== Install: drag-equivalent copy to /Applications (ditto keeps quarantine)"
MNT=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null || bad "hdiutil attach"
ls -la "$MNT"
[ -L "$MNT/Applications" ] && ok "DMG has Applications link" || bad "no Applications link"
# A Finder drag replaces the old app wholesale; ditto would merge into it and leave the old
# version's files (a stale helper then breaks the signature seal). Quit it, remove it.
pkill -x Korpora 2>/dev/null; sleep 1
rm -rf /Applications/Korpora.app
ditto "$MNT/Korpora.app" /Applications/Korpora.app
hdiutil detach "$MNT" >/dev/null
APP=/Applications/Korpora.app
xattr -p com.apple.quarantine "$APP" >/dev/null 2>&1 && ok "installed app is quarantined (real first-launch path)" || bad "quarantine not propagated"
spctl --assess --type execute -vv "$APP" 2>&1 | tee /tmp/s2
grep -q "source=Notarized Developer ID" /tmp/s2 && ok "app: Notarized Developer ID" || bad "app Gatekeeper"
if command -v syspolicy_check >/dev/null; then
  syspolicy_check distribution "$APP" 2>&1 | tail -3
  syspolicy_check distribution "$APP" >/dev/null 2>&1 && ok "syspolicy_check distribution" || bad "syspolicy_check distribution"
fi
codesign --verify --deep --strict "$APP" && ok "codesign strict verify" || bad "codesign verify"
/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" -c "Print LSMinimumSystemVersion" "$APP/Contents/Info.plist"

else
APP=/Applications/Korpora.app
echo "== Bundled pando, run from the installed app"
H="$APP/Contents/Helpers"
W=$(mktemp -d)
"$H/pando-index" "$SMOKE_DIR/smoke.conllu" "$W/idx" > /tmp/idx.log 2>&1
st=$?
tail -3 /tmp/idx.log
grep -qi "dyld\|Library not loaded" /tmp/idx.log && bad "dyld error in pando-index"
[ $st -eq 0 ] && ok "pando-index exit 0" || bad "pando-index exit $st"
grep -q "^size=8" "$W/idx/corpus.info" && ok "corpus written (8 tokens)" || bad "no corpus data"
# The engine library, loaded the way the app loads it, and asked a question.
python3 - "$APP/Contents/Frameworks/libpando.dylib" "$W/idx" <<'PY' > /tmp/lib.log 2>&1
import ctypes, json, sys
lib = ctypes.CDLL(sys.argv[1])
lib.pando_open.restype = ctypes.c_void_p
lib.pando_open.argtypes = [ctypes.c_char_p, ctypes.c_int]
lib.pando_query.restype = ctypes.c_void_p
lib.pando_query.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
h = lib.pando_open(sys.argv[2].encode(), 0)
assert h, "pando_open failed"
r = lib.pando_query(h, b'[upos="NOUN"]', b'{"total":true,"limit":5}')
page = json.loads(ctypes.string_at(r))["result"]["page"]
print("hits", page["total"])
PY
grep -q "^hits 2" /tmp/lib.log && ok "libpando loads and answers a query" || { cat /tmp/lib.log; bad "libpando did not answer"; }

echo "== App relaunch in the GUI session (after the manual first launch)"
sudo launchctl asuser "$(id -u)" sudo -u "$(id -un)" open -a "$APP"
sleep 6
pgrep -x Korpora >/dev/null && ok "app running" || bad "app not running after open"
log show --last 2m --predicate 'eventMessage CONTAINS "Library not loaded"' 2>/dev/null | grep -qi korpora && bad "dyld error in log" || ok "no dyld errors logged"
defaults read cz.cuni.mff.ufal.korpora migratedFromLegacyBundleID >/dev/null 2>&1 && ok "settings domain created (migration marker set on a fresh machine)" || bad "no settings domain"

fi
echo
echo "SUMMARY: $pass passed, $fail failed"
