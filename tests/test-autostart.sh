#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT_DIR/tools/bin/cor24-emu"

if grep -q 'CALL MENU' "$ROOT_DIR/system.plsw"; then
    echo "FAIL: system boot still calls MENU directly" >&2
    exit 1
fi

output=$($EMU --lgo "$ROOT_DIR/build/system.lgo" \
    -u '0' --speed 0 -n 1000000 --quiet 2>/dev/null)

if ! echo "$output" | grep -q 'SWTOS System Menu'; then
    echo "FAIL: autostart catalog did not launch the shell" >&2
    echo "$output" >&2
    exit 1
fi

menu_count=$(echo "$output" | grep -c 'SWTOS System Menu')
if [ "$menu_count" -ne 1 ]; then
    echo "FAIL: expected one autostart shell, saw $menu_count" >&2
    exit 1
fi

echo "PASS: IMAGE_AUTOSTART launched the shell through its catalog entry"
