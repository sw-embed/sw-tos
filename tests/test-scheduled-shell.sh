#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT_DIR/tools/bin/cor24-emu"
OUT_DIR="$ROOT_DIR/build/scheduled-shell"

"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-shell.plsw" scheduled-shell

output=$($EMU --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    -u '1x23\xFF\x01\xF4\x01\x00\xFF\x01\x58\x02\x00\xFF\x01\xBC\x02\x00\x1B4\xFF\x02\xC0\xFF\x03\x45\xFF\x02\x24\x1E\x45\xFF\x02\x88\x1E\x45\x1B0' \
    --speed 0 -n 3000000 --quiet 2>/dev/null \
    | sed '/^Entry point:/d')

for expected in 'Hello' 'B1' 'B2' 'Uptime' '00:05' '00:06' '00:07' 'Clock' '12:34:56' '12:34:57' '12:34:58' 'BYE'; do
    if ! echo "$output" | grep -q "$expected"; then
        echo "FAIL: scheduled menu output missing '$expected'" >&2
        echo "$output" >&2
        exit 1
    fi
done

menu_count=$(echo "$output" | grep -o 'MENU 1=Hello' | wc -l | tr -d ' ')
if [ "$menu_count" -ne 5 ]; then
    echo "FAIL: expected five scheduled menu displays, saw $menu_count" >&2
    echo "$output" >&2
    exit 1
fi

echo "PASS: persistent PL/SW menu scheduled Hello, Counter, Uptime, and Clock"
