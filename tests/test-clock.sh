#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT_DIR/tools/bin/cor24-emu"

output=$($EMU --lgo "$ROOT_DIR/build/system.lgo" \
    -u '3\xFF\x01\x00\x00\x00\xFF\x01\x64\x00\x00\xFF\x01\xC8\x00\x00\x1B0' \
    --speed 0 -n 5000000 --quiet 2>/dev/null)

for expected in '3: Clock' 'Clock uptime log' '00:00' '00:01' '00:02'; do
    if ! echo "$output" | grep -q "$expected"; then
        echo "FAIL: clock output missing '$expected'" >&2
        echo "$output" >&2
        exit 1
    fi
done

menu_count=$(echo "$output" | grep -c 'SWTOS System Menu')
if [ "$menu_count" -ne 2 ]; then
    echo "FAIL: expected Clock to return to menu once, saw $menu_count menus" >&2
    exit 1
fi

echo "PASS: Clock logged 00:00 through 00:02 and returned to menu"
