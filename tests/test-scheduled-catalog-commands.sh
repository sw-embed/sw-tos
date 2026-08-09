#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT_DIR/tools/bin/cor24-emu"
OUT_DIR="$ROOT_DIR/build/scheduled-shell"

"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-shell.plsw" scheduled-shell

output=$($EMU --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    -u 'ls\nrun counter\n0' --speed 0 -n 2000000 --quiet 2>/dev/null \
    | sed '/^Entry point:/d')

for expected in hello counter clock shell B1 B2 READY BYE; do
    if ! echo "$output" | grep -q "$expected"; then
        echo "FAIL: scheduled catalog command output missing '$expected'" >&2
        echo "$output" >&2
        exit 1
    fi
done

if echo "$output" | grep -q '^BAD$'; then
    echo "FAIL: valid scheduled catalog command was rejected" >&2
    exit 1
fi

echo "PASS: scheduled shell listed and ran catalog names"
