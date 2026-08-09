#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT_DIR/tools/bin/cor24-emu"
OUT_DIR="$ROOT_DIR/build/scheduled-multislot"

"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-multislot.plsw" scheduled-multislot

output=$($EMU --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    --speed 0 -n 1000000 --quiet 2>/dev/null \
    | sed '/^Entry point:/d')

expected='SPAWN
B1
C1
B2
C2
DONE'
if [ "$output" != "$expected" ]; then
    echo "FAIL: process-table scheduler output differed" >&2
    echo "expected:" >&2
    echo "$expected" >&2
    echo "actual:" >&2
    echo "$output" >&2
    exit 1
fi

echo "PASS: process-table scan scheduled two concurrent private-state children"
