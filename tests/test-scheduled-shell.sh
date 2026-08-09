#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT_DIR/tools/bin/cor24-emu"
OUT_DIR="$ROOT_DIR/build/scheduled-shell"

"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-shell.plsw" scheduled-shell

output=$($EMU --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    -u '1x23\xFF\x01\x00\x00\x00\xFF\x01\x64\x00\x00\xFF\x01\xC8\x00\x00\x1B0' \
    --speed 0 -n 3000000 --quiet 2>/dev/null \
    | sed '/^Entry point:/d')

for expected in 'Hello' 'B1' 'B2' 'Clock' '00:00' '00:01' '00:02' 'BYE'; do
    if ! echo "$output" | grep -q "$expected"; then
        echo "FAIL: scheduled menu output missing '$expected'" >&2
        echo "$output" >&2
        exit 1
    fi
done

menu_count=$(echo "$output" | grep -o 'MENU 1=Hello' | wc -l | tr -d ' ')
if [ "$menu_count" -ne 4 ]; then
    echo "FAIL: expected four scheduled menu displays, saw $menu_count" >&2
    echo "$output" >&2
    exit 1
fi

echo "PASS: persistent PL/SW menu scheduled Hello, Counter, and Clock"
