#!/usr/bin/env bash
# Builds the universal MacScreenAudio.driver (AudioServerPlugIn) into ./build and signs it.
# Runs the ring buffer unit test first.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$(pwd)"
SRC="$ROOT/AudioDriver"
OUT="$ROOT/build/MacScreenAudio.driver"
TMP="$ROOT/build/audio-driver-tmp"
CC=(xcrun clang -O2 -Wall -Wextra -Wno-unused-parameter -std=gnu11 -mmacosx-version-min=12.0)

mkdir -p "$ROOT/build"
rm -rf "$OUT" "$TMP"
mkdir -p "$TMP"

echo "Running ring buffer test"
"${CC[@]}" -o "$TMP/ring_test" "$SRC/tests/ring_test.c"
"$TMP/ring_test"

echo "Compiling driver (arm64 + x86_64)"
for ARCH in arm64 x86_64; do
    "${CC[@]}" -arch "$ARCH" -bundle -fvisibility=hidden \
        -Wl,-exported_symbol,_MacScreenAudio_Create \
        -framework CoreAudio -framework CoreFoundation \
        -o "$TMP/MacScreenAudio.$ARCH" "$SRC/MacScreenAudio.c"
done

mkdir -p "$OUT/Contents/MacOS"
lipo -create "$TMP/MacScreenAudio.arm64" "$TMP/MacScreenAudio.x86_64" -output "$OUT/Contents/MacOS/MacScreenAudio"
cp "$SRC/Info.plist" "$OUT/Contents/Info.plist"

echo "Checking the factory symbol is exported in every architecture"
for ARCH in arm64 x86_64; do
    if ! nm -gU -arch "$ARCH" "$OUT/Contents/MacOS/MacScreenAudio" | grep -q " _MacScreenAudio_Create$"; then
        echo "ERROR: _MacScreenAudio_Create is not exported ($ARCH); coreaudiod could not load the driver." >&2
        exit 1
    fi
done

echo "Running driver harness (loads the bundle and drives the AudioServerPlugIn interface)"
"${CC[@]}" -framework CoreAudio -framework CoreFoundation -o "$TMP/driver_harness" "$SRC/tests/driver_harness.c"
"$TMP/driver_harness" "$OUT"
rm -rf "$TMP"

if [[ -n "${MACSCREEN_SIGN_ID:-}" ]]; then
    ID="$MACSCREEN_SIGN_ID"
elif security find-identity -p codesigning 2>/dev/null | grep -q "MacScreen Dev"; then
    ID="MacScreen Dev"
else
    ID="-"
    echo "WARNING: signing ad-hoc. Run Scripts/make-dev-cert.sh once to create a stable signing identity." >&2
fi
echo "Signing identity: $ID"
codesign --force --sign "$ID" --identifier app.macscreen.audio "$OUT"

echo "Architectures: $(lipo -archs "$OUT/Contents/MacOS/MacScreenAudio")"
codesign -dv "$OUT" 2>&1 | grep -E "Identifier|Signature|Authority|TeamIdentifier" || true
echo "Built: $OUT"
