#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/scheduled-spi-provider"
MEDIA="$ROOT_DIR/build/catalog-images/swtos-storage.bin"

"$ROOT_DIR/scripts/cor24-storage.py" build "$MEDIA"
"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-spi.plsw" scheduled-spi-provider
# cor24-emu 0.1.0 attaches SPI devices in its LGO launch path but omits the
# attachment step in binary-only mode. Load a harmless LGO seed, then overlay
# the linked raw image using the emulator's documented combined mode.
"$ROOT_DIR/tools/bin/cor24-asm" "$ROOT_DIR/tests/spi-launch-seed.s" \
    -o "$OUT_DIR/seed.lgo"

output=$("$ROOT_DIR/tools/bin/cor24-emu" \
    --lgo "$OUT_DIR/seed.lgo" --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    --spi-device "w25q32@cs=3?file=$MEDIA" \
    --speed 0 -n 3000000 --quiet 2>/dev/null | sed '/^Entry point:/d')
expected='SPAWN
ESPI CACHE'
if [ "$output" != "$expected" ]; then
    echo "FAIL: expected SPI-backed spawn output:" >&2
    echo "$expected" >&2
    echo "actual:" >&2
    echo "$output" >&2
    exit 1
fi

echo "PASS: scheduled catalog lookup and executable load used W25Q32 storage"

CORRUPT_MEDIA="$OUT_DIR/corrupt-storage.bin"
cp "$MEDIA" "$CORRUPT_MEDIA"
printf 'X' | dd of="$CORRUPT_MEDIA" bs=1 seek=155 conv=notrunc 2>/dev/null
corrupt_output=$("$ROOT_DIR/tools/bin/cor24-emu" \
    --lgo "$OUT_DIR/seed.lgo" --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    --spi-device "w25q32@cs=3?file=$CORRUPT_MEDIA" \
    --speed 0 -n 3000000 --quiet 2>/dev/null | sed '/^Entry point:/d')
corrupt_expected='SPAWN
CRCFAIL'
if [ "$corrupt_output" != "$corrupt_expected" ]; then
    echo "FAIL: corrupt SPI payload was not rejected" >&2
    echo "actual:" >&2
    echo "$corrupt_output" >&2
    exit 1
fi

echo "PASS: target CRC rejected corrupt W25Q32 payload before execution"

for corruption in magic entry size; do
    bad_media="$OUT_DIR/corrupt-$corruption.bin"
    cp "$MEDIA" "$bad_media"
    if [ "$corruption" = magic ]; then
        printf 'X' | dd of="$bad_media" bs=1 seek=128 conv=notrunc 2>/dev/null
    elif [ "$corruption" = entry ]; then
        printf '\377\377\377' | dd of="$bad_media" bs=1 seek=146 conv=notrunc 2>/dev/null
    else
        printf '\377\377\377' | dd of="$bad_media" bs=1 seek=137 conv=notrunc 2>/dev/null
    fi
    bad_output=$("$ROOT_DIR/tools/bin/cor24-emu" \
        --lgo "$OUT_DIR/seed.lgo" --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
        --spi-device "w25q32@cs=3?file=$bad_media" \
        --speed 0 -n 3000000 --quiet 2>/dev/null | sed '/^Entry point:/d')
    if [ "$bad_output" != "$corrupt_expected" ]; then
        echo "FAIL: corrupt SPI $corruption was not rejected" >&2
        echo "$bad_output" >&2
        exit 1
    fi
done

echo "PASS: target rejected corrupt C24IMG magic, entry, and size metadata"
