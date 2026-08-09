#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ASM="$ROOT_DIR/tools/bin/cor24-asm"
EMU="$ROOT_DIR/tools/bin/cor24-emu"
SOURCE="$ROOT_DIR/hal/cor24/catalog-spawn.s"
OUT_DIR="$ROOT_DIR/build/catalog-spawn"

mkdir -p "$OUT_DIR"
"$ASM" "$SOURCE" -o "$OUT_DIR/catalog-spawn.lgo" \
    --bin "$OUT_DIR/catalog-spawn.bin" --listing "$OUT_DIR/catalog-spawn.lst"

output=$($EMU --lgo "$OUT_DIR/catalog-spawn.lgo" \
    --speed 0 -n 200000 --quiet 2>/dev/null)
expected=$'SPAWN\nA1\nB1\nA2\nB2'

if [ "$output" != "$expected" ]; then
    echo "FAIL: descriptor-backed spawn output mismatch" >&2
    printf 'Expected:\n%s\nActual:\n%s\n' "$expected" "$output" >&2
    exit 1
fi

echo "PASS: descriptor-sized spawn gave two instances private state"
