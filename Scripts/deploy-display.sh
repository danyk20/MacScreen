#!/usr/bin/env bash
# Copies MacScreen.app to the iMac (Display role) over SSH.
# Usage: Scripts/deploy-display.sh user@imac.local
# Requires Remote Login (System Settings > General > Sharing) enabled on the iMac, and SSH access
# (ideally this Mac's key in the iMac's ~/.ssh/authorized_keys).
set -euo pipefail

if [[ $# -ne 1 || "$1" == -h || "$1" == --help ]]; then
    echo "Usage: $0 user@imac.local" >&2
    exit 2
fi
TARGET="$1"

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$(pwd)"

"$ROOT/Scripts/make-app.sh"

ZIP="$ROOT/build/MacScreen.zip"
rm -f "$ZIP"
# ditto keeps the code signature, symlinks and extended attributes intact.
ditto -c -k --keepParent "$ROOT/build/MacScreen.app" "$ZIP"

REMOTE_ZIP="/tmp/MacScreen.zip"
scp "$ZIP" "$TARGET:$REMOTE_ZIP"
ssh "$TARGET" 'set -e
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/MacScreen.app"
unzip -q -o /tmp/MacScreen.zip -d "$HOME/Applications"
rm -f /tmp/MacScreen.zip
xattr -dr com.apple.quarantine "$HOME/Applications/MacScreen.app"'

cat <<MSG

Deployed to $TARGET:~/Applications/MacScreen.app

Launch on the iMac (Terminal there, or via ssh):
  ~/Applications/MacScreen.app/Contents/MacOS/MacScreen --role display
or:
  open ~/Applications/MacScreen.app --args --role display

On first launch, grant the permissions macOS asks for on the iMac.
MSG
