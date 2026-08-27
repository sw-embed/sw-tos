#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/interrupt-context-capability"
ASM="$ROOT_DIR/tools/bin/cor24-asm"

mkdir -p "$OUT_DIR"

# The supported interrupt return sequence must continue to assemble.
"$ASM" "$ROOT_DIR/hal/cor24/heartbeat.s" \
    -o "$OUT_DIR/heartbeat.lgo" >/dev/null

# Opcode C7 is a hardware-derived absolute immediate jump.  It supplies the
# final-register-safe resume path after an IR runway has recovered the PC.
"$ASM" "$ROOT_DIR/tests/absolute-jump-resume.s" \
    -o "$OUT_DIR/absolute-jump-resume.lgo" >/dev/null
output=$("$ROOT_DIR/tools/bin/cor24-emu" \
    --lgo "$OUT_DIR/absolute-jump-resume.lgo" \
    --speed 0 -n 200000 --quiet 2>/dev/null)
if [ "$output" != "J1" ]; then
    echo "FAIL: patched absolute jump did not preserve task state: $output" >&2
    exit 1
fi

# A preemptive switch needs software to save one interrupted PC and restore
# another. The current assembler/ISA exposes no legal transfer path for IR.
for fixture in ir-move-from ir-move-to ir-store ir-load; do
    if "$ASM" "$ROOT_DIR/tests/$fixture.s" \
        -o "$OUT_DIR/$fixture.lgo" >"$OUT_DIR/$fixture.log" 2>&1; then
        echo "FAIL: $fixture unexpectedly made IR software-visible" >&2
        exit 1
    fi
done

echo "PASS: IR is indirect-only; patched absolute jump preserves restored task state"
