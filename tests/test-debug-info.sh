#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/debug-info"

"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-tty-isolation.plsw" debug-info
python3 "$ROOT_DIR/scripts/generate-debug-info.py" \
    --binary "$OUT_DIR/program.bin" --map "$OUT_DIR/program.map" \
    --listing "$OUT_DIR/kernel.lst" --listing "$OUT_DIR/protocol.lst" \
    --listing "$OUT_DIR/app.lst" --output "$OUT_DIR/program.debug.json" --check
python3 "$ROOT_DIR/tests/test-debug-info.py" "$OUT_DIR"
