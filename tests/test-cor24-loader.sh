#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ASM="$ROOT_DIR/tools/bin/cor24-asm"
EMU="$ROOT_DIR/tools/bin/cor24-emu"
TOOL="$ROOT_DIR/scripts/cor24-image.py"
MANIFEST="$ROOT_DIR/catalog/images/loader-smoke.toml"
OUT_DIR="$ROOT_DIR/build/cor24-loader"

mkdir -p "$OUT_DIR"
"$TOOL" emit-asm "$MANIFEST" "$OUT_DIR/image.s" \
    --label _embedded_loader_smoke_image
cp "$ROOT_DIR/hal/cor24/image-loader.s" "$OUT_DIR/loader.s"
sed -n 'p' "$OUT_DIR/image.s" >> "$OUT_DIR/loader.s"
"$ASM" "$OUT_DIR/loader.s" -o "$OUT_DIR/loader.lgo" \
    --bin "$OUT_DIR/loader.bin" --listing "$OUT_DIR/loader.lst"

output=$($EMU --lgo "$OUT_DIR/loader.lgo" \
    --speed 0 -n 500000 --quiet 2>/dev/null)
expected='LOAD T2 D1 B2 E0 P1 Z1'
if [ "$output" != "$expected" ]; then
    echo "FAIL: expected '$expected', got '$output'" >&2
    exit 1
fi

echo "PASS: COR24 loader copied payload, cleared BSS, and relocated entry"
