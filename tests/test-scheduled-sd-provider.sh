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

CROSS_MEDIA="$OUT_DIR/two-sector-storage.bin"
"$ROOT_DIR/scripts/cor24-storage.py" build "$CROSS_MEDIA" \
    --image-alignment 512
"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-sd-cross-sector.plsw" scheduled-sd-cross-sector
cross_output=$("$ROOT_DIR/tools/bin/cor24-emu" \
    --lgo "$OUT_DIR/seed.lgo" \
    --load-binary "$ROOT_DIR/build/scheduled-sd-cross-sector/program.bin@0" --entry 0 \
    --spi-device "sdcard@cs=2?file=$CROSS_MEDIA" \
    --speed 0 -n 5000000 --quiet 2>/dev/null | sed '/^Entry point:/d')
if [ "$cross_output" != "$expected" ]; then
    echo "FAIL: SD provider did not load an application from sector one" >&2
    echo "$cross_output" >&2
    exit 1
fi

echo "PASS: catalog traversal and executable loading turned the SD cache over to sector one"

CROSS_IMAGE_MEDIA="$OUT_DIR/cross-sector-image-storage.bin"
"$ROOT_DIR/scripts/cor24-storage.py" build "$CROSS_IMAGE_MEDIA" \
    --manifest "$ROOT_DIR/tests/catalog-sd-cross-image.toml" \
    --image-alignment 512
"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-sd-cross-image.plsw" scheduled-sd-cross-image memory \
    "$ROOT_DIR/tests/catalog-sd-cross-image.toml"
cross_image_output=$("$ROOT_DIR/tools/bin/cor24-emu" \
    --lgo "$OUT_DIR/seed.lgo" \
    --load-binary "$ROOT_DIR/build/scheduled-sd-cross-image/program.bin@0" --entry 0 \
    --spi-device "sdcard@cs=2?file=$CROSS_IMAGE_MEDIA" \
    --speed 0 -n 5000000 --quiet 2>/dev/null | sed '/^Entry point:/d')
if [ "$cross_image_output" != "$expected" ]; then
    echo "FAIL: SD provider did not load an executable spanning sectors one and two" >&2
    echo "$cross_image_output" >&2
    exit 1
fi

echo "PASS: one authenticated executable read crossed from SD sector one into sector two"

TRUNCATED_CROSS_IMAGE_MEDIA="$OUT_DIR/truncated-cross-sector-image-storage.bin"
cp "$CROSS_IMAGE_MEDIA" "$TRUNCATED_CROSS_IMAGE_MEDIA"
truncate -s 1024 "$TRUNCATED_CROSS_IMAGE_MEDIA"
truncated_cross_output=$("$ROOT_DIR/tools/bin/cor24-emu" \
    --lgo "$OUT_DIR/seed.lgo" \
    --load-binary "$ROOT_DIR/build/scheduled-sd-cross-image/program.bin@0" --entry 0 \
    --spi-device "sdcard@cs=2?file=$TRUNCATED_CROSS_IMAGE_MEDIA" \
    --speed 0 -n 5000000 --quiet 2>/dev/null | sed '/^Entry point:/d')
if [ "$truncated_cross_output" != 'SPAWN' ]; then
    echo "FAIL: loader executed or accepted an image missing SD sector two" >&2
    echo "$truncated_cross_output" >&2
    exit 1
fi

echo "PASS: missing SD sector two rejected the partial image before execution"
