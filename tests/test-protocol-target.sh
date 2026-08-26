#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/protocol-v1"
ASM="$ROOT_DIR/tools/bin/cor24-asm"
META_GEN="$ROOT_DIR/tools/bin/meta-gen"
EMU="$ROOT_DIR/tools/bin/cor24-emu"

mkdir -p "$OUT_DIR"
sed -n 'p' "$ROOT_DIR/tests/protocol-v1-harness.s" \
    "$ROOT_DIR/hal/cor24/protocol-v1.s" > "$OUT_DIR/protocol-v1.raw.s"
"$META_GEN" prep "$OUT_DIR/protocol-v1.raw.s" \
    -o "$OUT_DIR/protocol-v1.s" --syms "$OUT_DIR/protocol-v1.syms"
"$ASM" "$OUT_DIR/protocol-v1.s" -o "$OUT_DIR/protocol-v1.lgo" \
    --bin "$OUT_DIR/protocol-v1.bin" --listing "$OUT_DIR/protocol-v1.lst"

# Valid TTY payload containing literal sync, bad checksum, unknown type, then
# a valid fragmented-stream-equivalent WallClock frame.
output=$($EMU --lgo "$OUT_DIR/protocol-v1.lgo" \
    -u 'junk\xA5\x5A\x01\x01\x02\x02\x00\xA5\x5A\x05\xA5\x5A\x01\x01\x00\x00\x00\x03\xA5\x5A\x01\xFE\x00\x00\x00\xFF\xA5\x5A\x01\x07\x00\x03\x00\x01\x00\x00\x0C\xA5\x5A\x01\x06\x00\x03\x00\xFF\x1D\x01\x27' \
    --speed 0 -n 1000000 --quiet 2>/dev/null)

if [ "$output" != 'A2EEG3F3' ]; then
    echo "FAIL: target protocol decoder produced '$output', expected 'A2EEG3F3'" >&2
    exit 1
fi

echo "PASS: COR24 framed decoder rejects corruption and resynchronizes"
