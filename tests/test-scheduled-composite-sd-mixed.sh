#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/scheduled-composite-sd-mixed"
MEDIA="$ROOT_DIR/build/catalog-images/swtos-storage.bin"

"$ROOT_DIR/scripts/cor24-storage.py" build "$MEDIA"
"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-composite-sd-mixed.plsw" \
    scheduled-composite-sd-mixed composite-sd
"$ROOT_DIR/tools/bin/cor24-asm" "$ROOT_DIR/tests/spi-launch-seed.s" \
    -o "$OUT_DIR/seed.lgo"

output=$("$ROOT_DIR/scripts/swtos-emu" --lgo "$OUT_DIR/seed.lgo" \
    --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    --spi-device "sdcard@cs=2?file=$MEDIA" \
    --speed 0 -n 5000000 --quiet 2>/dev/null | sed '/^Entry point:/d')

for marker in MIXED B1 B2 E RECLAIMED; do
    if ! printf '%s' "$output" | grep -q "$marker"; then
        echo "FAIL: mixed resident/SD proof is missing $marker" >&2
        echo "$output" >&2
        exit 1
    fi
done

echo "PASS: concurrent resident and SD children retained distinct sources and allocations"
