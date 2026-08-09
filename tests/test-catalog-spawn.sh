#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT_DIR/tools/bin/cor24-emu"
OUT_DIR="$ROOT_DIR/build/catalog-spawn"

"$ROOT_DIR/scripts/catalog-spawn-link.sh"

output=$($EMU --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    --speed 0 -n 300000 --quiet 2>/dev/null | sed '/^Entry point:/d')
expected=$'SPAWN\nA1\nB1\nA2\nB2'

if [ "$output" != "$expected" ]; then
    echo "FAIL: descriptor-backed spawn output mismatch" >&2
    printf 'Expected:\n%s\nActual:\n%s\n' "$expected" "$output" >&2
    exit 1
fi

echo "PASS: running PL/SW task spawned a second private-state instance"
