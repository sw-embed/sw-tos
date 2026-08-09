#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT_DIR/tools/bin/cor24-emu"
OUT_DIR="$ROOT_DIR/build/scheduled-shell"

"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-shell.plsw" scheduled-shell

output=$($EMU --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    -u 'ls\nrun missing\nrun shell\nrun counter\n0' \
    --speed 0 -n 2000000 --quiet 2>/dev/null \
    | sed '/^Entry point:/d')

for expected in hello counter clock shell B1 B2 READY BYE; do
    if ! echo "$output" | grep -q "$expected"; then
        echo "FAIL: scheduled catalog command output missing '$expected'" >&2
        echo "$output" >&2
        exit 1
    fi
done

bad_count=$(echo "$output" | grep -o 'BAD' | wc -l | tr -d ' ')
if [ "$bad_count" -ne 2 ]; then
    echo "FAIL: expected missing program and service name to be rejected" >&2
    echo "$output" >&2
    exit 1
fi

echo "PASS: scheduled shell listed and ran catalog names"
