#!/usr/bin/env bash
# Packages build/MacScreen.app into a compressed disk image with an Applications shortcut.
# Usage: Scripts/make-dmg.sh <output.dmg>   (run Scripts/make-app.sh first)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
OUT="${1:?usage: Scripts/make-dmg.sh <output.dmg>}"
APP="build/MacScreen.app"
[[ -d "$APP" ]] || { echo "Missing $APP. Run Scripts/make-app.sh first." >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/MacScreen.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME FIRST.txt" <<'T'
Install: drag MacScreen onto the Applications folder.

This build is not notarized by Apple. The first time you open it, right-click MacScreen
in Applications and choose Open (then Open again). After that it opens normally.

Run MacScreen on both Macs: choose "Use as Host" on the Mac whose screen you want to extend,
"Use as Display" on the Mac that will show it. Details: https://github.com/danyk20/MacScreen
T

rm -f "$OUT"
hdiutil create -quiet -volname "MacScreen" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$OUT"
hdiutil verify -quiet "$OUT"
echo "Built: $OUT ($(du -h "$OUT" | cut -f1))"
