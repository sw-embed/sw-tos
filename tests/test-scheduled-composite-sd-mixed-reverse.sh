#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/scheduled-composite-sd-mixed-reverse"
MEDIA="$ROOT_DIR/build/catalog-images/swtos-storage.bin"

"$ROOT_DIR/scripts/cor24-storage.py" build "$MEDIA"
"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-composite-sd-mixed-reverse.plsw" \
    scheduled-composite-sd-mixed-reverse composite-sd
"$ROOT_DIR/tools/bin/cor24-asm" "$ROOT_DIR/tests/spi-launch-seed.s" \
    -o "$OUT_DIR/seed.lgo"

output=$("$ROOT_DIR/tools/bin/cor24-emu" --lgo "$OUT_DIR/seed.lgo" \
    --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    --spi-device "sdcard@cs=2?file=$MEDIA" \
    --speed 0 -n 5000000 --quiet 2>/dev/null | sed '/^Entry point:/d')

for marker in REVERSE E C1 C2 RECLAIMED; do
    if ! printf '%s' "$output" | grep -q "$marker"; then
        echo "FAIL: reverse mixed resident/SD proof is missing $marker" >&2
        echo "$output" >&2
        exit 1
    fi
done

echo "PASS: later resident lookup preserved the live SD child source and allocation"
