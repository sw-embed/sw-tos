#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/scheduled-tty"
EMU="$ROOT_DIR/scripts/swtos-emu"

"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-tty-isolation.plsw" scheduled-tty

output=$($EMU --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    -u 'XY' --speed 0 -n 500000 --quiet 2>/dev/null \
    | sed '/^Entry point:/d')

if ! grep -q $'SPAWN\nXY' <<<"$output"; then
    echo "FAIL: independently blocked readers did not receive foreground bytes in order" >&2
    echo "$output" >&2
    exit 1
fi

blocked_dump=$($EMU --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    --speed 0 -n 500000 --quiet --trace 300 2>&1)
if ! grep -q 'lw      r0,24(r2).*0x000007' <<<"$blocked_dump"; then
    echo "FAIL: empty virtual-TTY readers did not remain blocked without redispatch" >&2
    echo "$blocked_dump" >&2
    exit 1
fi

echo "PASS: virtual TTYs isolate input and blocked readers yield until wakeup"
