#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/scheduled-sd-provider"
MEDIA="$ROOT_DIR/build/catalog-images/swtos-storage.bin"

"$ROOT_DIR/scripts/cor24-storage.py" build "$MEDIA"
"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-sd.plsw" scheduled-sd-provider
"$ROOT_DIR/tools/bin/cor24-asm" "$ROOT_DIR/tests/spi-launch-seed.s" \
    -o "$OUT_DIR/seed.lgo"

output=$("$ROOT_DIR/tools/bin/cor24-emu" \
    --lgo "$OUT_DIR/seed.lgo" \
    --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    --spi-device "sdcard@cs=2?file=$MEDIA" \
    --speed 0 -n 5000000 --quiet 2>/dev/null | sed '/^Entry point:/d')

expected='SPAWN
ESD CACHE'
if [ "$output" != "$expected" ]; then
    echo "FAIL: expected SD-backed catalog spawn output:" >&2
    echo "$expected" >&2
    echo "actual:" >&2
    echo "$output" >&2
    exit 1
fi

echo "PASS: catalog lookup and executable load used cached SD sectors"

CORRUPT_MEDIA="$OUT_DIR/corrupt-storage.bin"
cp "$MEDIA" "$CORRUPT_MEDIA"
printf 'X' | dd of="$CORRUPT_MEDIA" bs=1 seek=179 conv=notrunc status=none
corrupt_output=$("$ROOT_DIR/tools/bin/cor24-emu" \
    --lgo "$OUT_DIR/seed.lgo" \
    --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    --spi-device "sdcard@cs=2?file=$CORRUPT_MEDIA" \
    --speed 0 -n 5000000 --quiet 2>/dev/null | sed '/^Entry point:/d')
corrupt_expected='SPAWN
SDFAIL'
if [ "$corrupt_output" != "$corrupt_expected" ]; then
    echo "FAIL: corrupt SD-backed executable was not rejected" >&2
    echo "$corrupt_output" >&2
    exit 1
fi

echo "PASS: target CRC rejected a corrupt SD-backed executable"
