#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ASM="$ROOT_DIR/tools/bin/cor24-asm"
EMU="$ROOT_DIR/tools/bin/cor24-emu"
SOURCE="$ROOT_DIR/hal/cor24/context-switch.s"
OUT_DIR="$ROOT_DIR/build/context-switch"

mkdir -p "$OUT_DIR"
"$ASM" "$SOURCE" -o "$OUT_DIR/context-switch.lgo" \
    --bin "$OUT_DIR/context-switch.bin" \
    --listing "$OUT_DIR/context-switch.lst"

output=$($EMU --lgo "$OUT_DIR/context-switch.lgo" \
    --speed 0 -n 100000 --quiet 2>/dev/null)
expected=$'SWTOS M1\nA1\nB1\nA2\nB2\nA3\nB3'

if [ "$output" != "$expected" ]; then
    echo "FAIL: cooperative context-switch output mismatch" >&2
    printf 'Expected:\n%s\nActual:\n%s\n' "$expected" "$output" >&2
    exit 1
fi

echo "PASS: blocked IPC client and TTY service alternated on separate stacks"
