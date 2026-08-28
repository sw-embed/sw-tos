#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/scheduled-concurrent-spi"
MEDIA="$ROOT_DIR/build/catalog-images/swtos-storage.bin"

"$ROOT_DIR/scripts/cor24-storage.py" build "$MEDIA"
"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-spi-concurrent.plsw" scheduled-concurrent-spi composite-spi
"$ROOT_DIR/tools/bin/cor24-asm" "$ROOT_DIR/tests/spi-launch-seed.s" \
    -o "$OUT_DIR/seed.lgo"

output=$("$ROOT_DIR/scripts/swtos-emu" --lgo "$OUT_DIR/seed.lgo" \
    --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    --spi-device "w25q32@cs=3?file=$MEDIA" \
    --speed 0 -n 3000000 --quiet 2>/dev/null | sed '/^Entry point:/d')

if ! echo "$output" | grep -q 'SNAPSHOT'; then
    echo "FAIL: live SPI children did not retain distinct descriptor snapshots" >&2
    echo "$output" >&2
    exit 1
fi
if ! echo "$output" | grep -q 'EP'; then
    echo "FAIL: two concurrently runnable SPI images did not execute independently" >&2
    echo "$output" >&2
    exit 1
fi

echo "PASS: two live SPI children retained independent descriptors and images"
