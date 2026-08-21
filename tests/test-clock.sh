#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT_DIR/tools/bin/cor24-emu"

output=$($EMU --lgo "$ROOT_DIR/build/system.lgo" \
    -u '3\xFF\x01\xF4\x01\x00\xFF\x01\x58\x02\x00\xFF\x01\xBC\x02\x00\x1B4\xFF\x02\xC0\xFF\x03\x45\xFF\x02\x24\x1E\x45\xFF\x02\x88\x1E\x45\x1B0' \
    --speed 0 -n 5000000 --quiet 2>/dev/null)

for expected in '3: Uptime' '4: Clock' 'Uptime' '00:05' '00:06' '00:07' 'Clock' '12:34:56' '12:34:57' '12:34:58'; do
    if ! echo "$output" | grep -q "$expected"; then
        echo "FAIL: clock output missing '$expected'" >&2
        echo "$output" >&2
        exit 1
    fi
done

menu_count=$(echo "$output" | grep -c 'SWTOS System Menu')
if [ "$menu_count" -ne 4 ]; then
    echo "FAIL: expected both time apps and invalid 0 to return to menu, saw $menu_count menus" >&2
    exit 1
fi

echo "PASS: Uptime used connection time and Clock used wall time"
