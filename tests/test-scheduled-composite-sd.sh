#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/scheduled-shell-sd"
MEDIA="$ROOT_DIR/build/catalog-images/swtos-storage.bin"

"$ROOT_DIR/scripts/cor24-storage.py" build "$MEDIA"
"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-shell.plsw" scheduled-shell-sd composite-sd
"$ROOT_DIR/tools/bin/cor24-asm" "$ROOT_DIR/tests/spi-launch-seed.s" \
    -o "$OUT_DIR/seed.lgo"

output=$("$ROOT_DIR/tools/bin/cor24-emu" --lgo "$OUT_DIR/seed.lgo" \
    --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    --spi-device "sdcard@cs=2?file=$MEDIA" \
    -u 'run embedded-hello\nrun embedded-ping\nrun counter\n0' \
    --speed 0 -n 6000000 --quiet 2>/dev/null | sed '/^Entry point:/d')

for expected in EREADY PREADY B1 B2; do
    if ! echo "$output" | grep -q "$expected"; then
        echo "FAIL: SD composite shell output missing $expected" >&2
        echo "$output" >&2
        exit 1
    fi
done

echo "PASS: interactive catalog used resident-first lookup with SD fallback"
