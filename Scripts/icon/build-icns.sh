#!/usr/bin/env bash
# Regenerates Resources/AppIcon.icns and Resources/MenuBarIcon@2x.png from make-icon.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
swift "$ROOT/Scripts/icon/make-icon.swift" "$T"
S="$T/AppIcon.iconset"; mkdir "$S"
for sz in 16 32 128 256 512; do
  sips -z $sz $sz "$T/icon_1024.png" --out "$S/icon_${sz}x${sz}.png" >/dev/null
  sips -z $((sz*2)) $((sz*2)) "$T/icon_1024.png" --out "$S/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$S" -o "$ROOT/Resources/AppIcon.icns"
cp "$T/menubar_template.png" "$ROOT/Resources/MenuBarIcon@2x.png"
echo "wrote Resources/AppIcon.icns and Resources/MenuBarIcon@2x.png"
