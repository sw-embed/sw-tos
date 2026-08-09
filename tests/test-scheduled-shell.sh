#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT_DIR/tools/bin/cor24-emu"
OUT_DIR="$ROOT_DIR/build/scheduled-shell"

"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-shell.plsw" scheduled-shell

output=$($EMU --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    -u 'run counter\n' --speed 0 -n 500000 --quiet 2>/dev/null \
    | sed '/^Entry point:/d')
expected=$'SPAWN\nSHELL\nB1\nB2\nRESUMED'

if [ "$output" != "$expected" ]; then
    echo "FAIL: scheduled shell run path mismatch" >&2
    printf 'Expected:\n%s\nActual:\n%s\n' "$expected" "$output" >&2
    exit 1
fi

echo "PASS: PL/SW shell spawned and scheduled run counter"
