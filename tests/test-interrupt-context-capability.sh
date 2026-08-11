#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/interrupt-context-capability"
ASM="$ROOT_DIR/tools/bin/cor24-asm"

mkdir -p "$OUT_DIR"

# The supported interrupt return sequence must continue to assemble.
"$ASM" "$ROOT_DIR/hal/cor24/heartbeat.s" \
    -o "$OUT_DIR/heartbeat.lgo" >/dev/null

# A preemptive switch needs software to save one interrupted PC and restore
# another. The current assembler/ISA exposes no legal transfer path for IR.
for fixture in ir-move-from ir-move-to ir-store ir-load; do
    if "$ASM" "$ROOT_DIR/tests/$fixture.s" \
        -o "$OUT_DIR/$fixture.lgo" >"$OUT_DIR/$fixture.log" 2>&1; then
        echo "FAIL: $fixture unexpectedly made IR software-visible" >&2
        exit 1
    fi
done

echo "PASS: COR24 can return through IR but cannot save or restore it"
