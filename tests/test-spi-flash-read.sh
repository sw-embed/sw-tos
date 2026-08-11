#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/spi-flash-read"
MEDIA="$ROOT_DIR/build/catalog-images/swtos-storage.bin"

mkdir -p "$OUT_DIR"
"$ROOT_DIR/scripts/cor24-storage.py" build "$MEDIA"
cp "$ROOT_DIR/tests/spi-flash-read.s" "$OUT_DIR/program.s"
sed -n 'p' "$ROOT_DIR/hal/cor24/spi.s" >> "$OUT_DIR/program.s"
"$ROOT_DIR/tools/bin/cor24-asm" "$OUT_DIR/program.s" \
    -o "$OUT_DIR/program.lgo" --listing "$OUT_DIR/program.lst"

output=$("$ROOT_DIR/tools/bin/cor24-emu" --lgo "$OUT_DIR/program.lgo" \
    --spi-device "w25q32@cs=3?file=$MEDIA" --speed 0 -n 100000 --quiet 2>/dev/null)
if [ "$output" != "S" ]; then
    echo "FAIL: expected S, got '$output'" >&2
    exit 1
fi

echo "PASS: COR24 SPI HAL read generated media through W25Q32"
