#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/scheduled-protocol"
EMU="$ROOT_DIR/tools/bin/cor24-emu"

"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-tty-isolation.plsw" scheduled-protocol

# Initial and reconnect HELLOs followed by one byte for channels one and two.
"$EMU" --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    -u '\xA5\x5A\x01\x0C\x00\x04\x00SWT1\x40\xA5\x5A\x01\x0C\x00\x04\x00SWT1\x40\xA5\x5A\x01\x01\x01\x01\x00X\x5C\xA5\x5A\x01\x01\x02\x01\x00Y\x5E' \
    --speed 0 -n 1000000 --quiet 2>/dev/null > "$OUT_DIR/output.bin"

python3 "$ROOT_DIR/tests/assert-protocol-negotiation.py" \
    "$OUT_DIR/output.bin" "$OUT_DIR/kernel.lst"

TIME_DIR="$ROOT_DIR/build/scheduled-protocol-time"
"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-protocol-time.plsw" scheduled-protocol-time

# Uptime payload FF 1D 01 exercises internal escaping; checksum 0x27.
"$EMU" --load-binary "$TIME_DIR/program.bin@0" --entry 0 \
    -u '\xA5\x5A\x01\x0C\x00\x04\x00SWT1\x40\xA5\x5A\x01\x06\x00\x03\x00\xFF\x1D\x01\x27' \
    --speed 0 -n 1000000 --quiet 2>/dev/null > "$TIME_DIR/output.bin"

python3 "$ROOT_DIR/tests/assert-protocol-time.py" "$TIME_DIR/output.bin"
