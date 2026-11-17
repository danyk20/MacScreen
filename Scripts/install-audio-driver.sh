#!/usr/bin/env bash
# Installs build/MacScreenAudio.driver into /Library/Audio/Plug-Ins/HAL and restarts coreaudiod.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
SRC="$(pwd)/build/MacScreenAudio.driver"
DEST_DIR="/Library/Audio/Plug-Ins/HAL"
DEST="$DEST_DIR/MacScreenAudio.driver"

if [[ ! -d "$SRC" ]]; then
    echo "Missing $SRC. Run Scripts/build-audio-driver.sh first." >&2
    exit 1
fi

echo "This will:"
echo "  1. sudo rm -rf $DEST (if present)"
echo "  2. sudo cp -R $SRC $DEST_DIR/"
echo "  3. sudo killall coreaudiod (all system audio restarts for a moment)"
read -r -p "Continue? [y/N] " ANSWER
if [[ "$ANSWER" != "y" && "$ANSWER" != "Y" ]]; then
    echo "Aborted."
    exit 1
fi

sudo mkdir -p "$DEST_DIR"
sudo rm -rf "$DEST"
sudo cp -R "$SRC" "$DEST_DIR/"
sudo chown -R root:wheel "$DEST"
sudo killall coreaudiod || true
echo "Installed. The device \"MacScreen Display\" should appear in Sound settings within a few seconds."
echo
echo "Check it registered:"
echo "  system_profiler SPAudioDataType | grep -A3 'MacScreen Display'"
echo "If nothing shows up, look for load errors (e.g. \"Cannot find function pointer\", code signing):"
echo "  log show --last 2m --predicate 'process == \"coreaudiod\" OR process CONTAINS \"Driver-Service\"' | grep -i macscreen"
