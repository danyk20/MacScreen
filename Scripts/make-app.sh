#!/usr/bin/env bash
# Builds a universal MacScreen.app and msprobe into ./build and signs them.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$(pwd)"

ARCHS=(--arch arm64 --arch x86_64)

swift build -c release "${ARCHS[@]}" --product MacScreen
swift build -c release "${ARCHS[@]}" --product msprobe
BIN_PATH="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

APP="$ROOT/build/MacScreen.app"
rm -rf "$APP" "$ROOT/build/msprobe"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_PATH/MacScreen" "$APP/Contents/MacOS/MacScreen"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/Resources/AppIcon.icns" "$ROOT/Resources/MenuBarIcon@2x.png" "$APP/Contents/Resources/"
cp "$BIN_PATH/msprobe" "$ROOT/build/msprobe"

if [[ -n "${MACSCREEN_SIGN_ID:-}" ]]; then
    ID="$MACSCREEN_SIGN_ID"
elif security find-identity -p codesigning 2>/dev/null | grep -q "MacScreen Dev"; then
    ID="MacScreen Dev"
else
    ID="-"
    echo "WARNING: signing ad-hoc. Screen Recording permission will be reset on every rebuild." >&2
    echo "         Run Scripts/make-dev-cert.sh once to create a stable signing identity." >&2
fi
echo "Signing identity: $ID"

codesign --force --sign "$ID" --identifier app.macscreen.MacScreen "$APP"
codesign --force --sign "$ID" --identifier app.macscreen.msprobe "$ROOT/build/msprobe"

echo
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/MacScreen")"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|Authority|TeamIdentifier" || true
echo "Built: $APP"
