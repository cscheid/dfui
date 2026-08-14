#!/usr/bin/env bash
# Builds dfui and installs it to ~/Applications, replacing any running instance.
#
# The login item registration (SMAppService) records the bundle's path, so the
# installed copy — not dist/ inside the working tree — is what should be
# registered. Rebuilding does NOT update the installed app: run this script
# again after any change you want to keep.
set -euo pipefail

cd "$(dirname "$0")/.."

DEST_DIR="${DEST_DIR:-$HOME/Applications}"
DEST="$DEST_DIR/dfui.app"

./scripts/build-app.sh

# Quit the installed copy if it is running, so we are not overwriting a live
# bundle. The running dist/ copy, if any, is left alone. If it was running we
# relaunch at the end — otherwise a reinstall silently empties the menu bar.
WAS_RUNNING=0
if pgrep -f "^${DEST}/Contents/MacOS/dfui$" >/dev/null 2>&1; then
    WAS_RUNNING=1
    echo "stopping running $DEST"
    pkill -f "^${DEST}/Contents/MacOS/dfui$" || true
    # Give launchd a moment to reap it before the bundle moves under it.
    for _ in $(seq 20); do
        pgrep -f "^${DEST}/Contents/MacOS/dfui$" >/dev/null 2>&1 || break
        sleep 0.1
    done
fi

mkdir -p "$DEST_DIR"
rm -rf "$DEST"
cp -R dist/dfui.app "$DEST"

# Drop the quarantine bit; it is not applicable to a locally built app and
# would otherwise trigger a Gatekeeper prompt.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "installed $DEST"

if [ "$WAS_RUNNING" = 1 ]; then
    open "$DEST"
    echo "relaunched $DEST"
else
    echo
    echo "Launch it with:  open \"$DEST\""
    echo "Then enable 'Open at Login' from the menu bar item to start it on boot."
fi

echo
echo "NOTE: rebuilding the project does not update $DEST."
echo "      Re-run this script after any change you want to keep."
