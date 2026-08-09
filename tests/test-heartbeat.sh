#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ASM="$ROOT_DIR/tools/bin/cor24-asm"
EMU="$ROOT_DIR/tools/bin/cor24-emu"
SOURCE="$ROOT_DIR/hal/cor24/heartbeat.s"
OUT_DIR="$ROOT_DIR/build/heartbeat"

mkdir -p "$OUT_DIR"
"$ASM" "$SOURCE" -o "$OUT_DIR/heartbeat.lgo" \
    --bin "$OUT_DIR/heartbeat.bin" --listing "$OUT_DIR/heartbeat.lst"

# Ordinary x + escaped FF are two data bytes. Heartbeats FFFFFE and 000001
# are three ticks apart across the natural 24-bit wrap boundary.
output=$($EMU --lgo "$OUT_DIR/heartbeat.lgo" \
    -u 'x\xFF\x00\xFF\x01\xFE\xFF\xFF\xFF\x01\x01\x00\x00' \
    --speed 0 -n 200000 --quiet 2>/dev/null)
expected='T3 D2 W2'

if [ "$output" != "$expected" ]; then
    echo "FAIL: expected '$expected', got '$output'" >&2
    exit 1
fi

echo "PASS: UART framing and 24-bit heartbeat wrap produced $output"
