#!/usr/bin/env bash
# Removes MacScreenAudio.driver from /Library/Audio/Plug-Ins/HAL and restarts coreaudiod.
set -euo pipefail

DEST="/Library/Audio/Plug-Ins/HAL/MacScreenAudio.driver"

if [[ ! -d "$DEST" ]]; then
    echo "Not installed: $DEST"
    exit 0
fi

echo "This will:"
echo "  1. sudo rm -rf $DEST"
echo "  2. sudo killall coreaudiod (all system audio restarts for a moment)"
read -r -p "Continue? [y/N] " ANSWER
if [[ "$ANSWER" != "y" && "$ANSWER" != "Y" ]]; then
    echo "Aborted."
    exit 1
fi

sudo rm -rf "$DEST"
sudo killall coreaudiod || true
echo "Uninstalled."
