#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT_DIR/tools/bin/cor24-emu"
OUT_DIR="$ROOT_DIR/build/scheduled-shell"

"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-shell.plsw" scheduled-shell

output=$($EMU --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    -u '1\nx2\n0\n' --speed 0 -n 1000000 --quiet 2>/dev/null \
    | sed '/^Entry point:/d')
expected=$'SPAWN\nMENU 1=Hello 2=Counter 0=Exit\nChoice: Hello\nPress key\nREADY\nMENU 1=Hello 2=Counter 0=Exit\nChoice: B1\nB2\nREADY\nMENU 1=Hello 2=Counter 0=Exit\nChoice: BYE'

if [ "$output" != "$expected" ]; then
    echo "FAIL: scheduled shell run path mismatch" >&2
    printf 'Expected:\n%s\nActual:\n%s\n' "$expected" "$output" >&2
    exit 1
fi

echo "PASS: persistent PL/SW menu scheduled Hello and Counter"
