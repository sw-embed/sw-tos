#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/scheduled-shell-spi"
MEDIA="$ROOT_DIR/build/catalog-images/swtos-storage.bin"

"$ROOT_DIR/scripts/cor24-storage.py" build "$MEDIA"
"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-shell.plsw" scheduled-shell-spi composite-spi
"$ROOT_DIR/tools/bin/cor24-asm" "$ROOT_DIR/tests/spi-launch-seed.s" \
    -o "$OUT_DIR/seed.lgo"

output=$("$ROOT_DIR/tools/bin/cor24-emu" --lgo "$OUT_DIR/seed.lgo" \
    --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    --spi-device "w25q32@cs=3?file=$MEDIA" \
    -u 'run embedded-hello\nrun embedded-ping\nrun counter\n0' \
    --speed 0 -n 3000000 --quiet 2>/dev/null | sed '/^Entry point:/d')

if ! echo "$output" | grep -q 'EREADY'; then
    echo "FAIL: composite provider did not execute SPI embedded-hello" >&2
    echo "$output" >&2
    exit 1
fi
if ! echo "$output" | grep -q 'PREADY'; then
    echo "FAIL: composite provider did not execute second SPI image" >&2
    echo "$output" >&2
    exit 1
fi
for expected in B1 B2 BYE; do
    if ! echo "$output" | grep -q "$expected"; then
        echo "FAIL: composite provider resident fallback missing $expected" >&2
        echo "$output" >&2
        exit 1
    fi
done

echo "PASS: interactive catalog used resident-first lookup with SPI fallback"
