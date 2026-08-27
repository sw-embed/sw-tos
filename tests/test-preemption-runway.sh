#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/preemption-runway"
ASM="$ROOT_DIR/tools/bin/cor24-asm"
EMU="$ROOT_DIR/tools/bin/cor24-emu"

mkdir -p "$OUT_DIR"
"$ASM" "$ROOT_DIR/hal/cor24/preemption-runway.s" \
    -o "$OUT_DIR/preemption-runway.lgo" \
    --bin "$OUT_DIR/preemption-runway.bin" \
    --listing "$OUT_DIR/preemption-runway.lst"

output=$("$EMU" --lgo "$OUT_DIR/preemption-runway.lgo" \
    -u 'x' --speed 0 -n 500000 --quiet 2>/dev/null)
if [ "$output" != "P1" ]; then
    echo "FAIL: expected P1 from IR runway resume, got '$output'" >&2
    exit 1
fi

echo "PASS: UART IRQ recovered exact IR and resumed the CPU hog: $output"
