#!/bin/bash
# Installs the Tart Guest Agent in a Tart macOS VM, once, so that the host can run commands in it with
# `tart exec <vm> <command>` (no SSH, no keys). Run it INSIDE the VM, from the shared folder:
#
#   sudo bash "/Volumes/My Shared Files/smoke/install-tart-guest-agent.sh"
#
# The folder holds tart-guest-agent-darwin-all.tar.gz and checksums.txt from
# https://github.com/cirruslabs/tart-guest-agent/releases (v0.15.0); the archive is checked against the checksum.
# The agent goes in /usr/local/bin (not /opt/homebrew: the smoke test wants no Homebrew in the VM) and runs as a
# launchd global agent, as in Cirrus's own images. Also turns Gatekeeper on, which the Cirrus vanilla image
# ships without. After this, stop the VM and `tart clone` it as the base for later smoke tests.
set -eu
[ "$(id -u)" = 0 ] || { echo "run it with sudo"; exit 1; }
DIR="$(cd "$(dirname "$0")" && pwd)"
ARCHIVE="$DIR/tart-guest-agent-darwin-all.tar.gz"
[ -f "$ARCHIVE" ] || { echo "no $ARCHIVE"; exit 1; }
want="$(grep 'darwin-all.tar.gz' "$DIR/checksums.txt" | awk '{print $1}')"
have="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
[ -n "$want" ] && [ "$want" = "$have" ] || { echo "checksum does not match: $have"; exit 1; }
WORK="$(mktemp -d)"
tar -xzf "$ARCHIVE" -C "$WORK"
mkdir -p /usr/local/bin
install -m 755 "$WORK/tart-guest-agent" /usr/local/bin/tart-guest-agent
rm -rf "$WORK"
cat > /Library/LaunchAgents/org.cirruslabs.tart-guest-agent.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>org.cirruslabs.tart-guest-agent</string>
    <key>ProgramArguments</key>
    <array><string>/usr/local/bin/tart-guest-agent</string><string>--run-agent</string></array>
    <key>EnvironmentVariables</key>
    <dict><key>PATH</key><string>/bin:/usr/bin:/usr/sbin:/usr/local/bin</string><key>TERM</key><string>xterm-256color</string></dict>
    <key>WorkingDirectory</key><string>/Users/admin</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/tmp/tart-guest-agent.log</string>
    <key>StandardErrorPath</key><string>/tmp/tart-guest-agent.log</string>
</dict>
</plist>
PLIST
chown root:wheel /Library/LaunchAgents/org.cirruslabs.tart-guest-agent.plist
chmod 644 /Library/LaunchAgents/org.cirruslabs.tart-guest-agent.plist
spctl --global-enable
# Start it now in the logged-in user's session (it starts by itself at every login).
USER_ID="$(id -u "${SUDO_USER:-admin}")"
launchctl bootout "gui/$USER_ID/org.cirruslabs.tart-guest-agent" 2>/dev/null || true
launchctl bootstrap "gui/$USER_ID" /Library/LaunchAgents/org.cirruslabs.tart-guest-agent.plist
sleep 2
pgrep -x tart-guest-agent >/dev/null && echo "tart-guest-agent is running" || { echo "not running, see /tmp/tart-guest-agent.log"; exit 1; }
spctl --status
