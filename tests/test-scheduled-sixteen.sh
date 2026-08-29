#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT_DIR/scripts/swtos-emu"
OUT_DIR="$ROOT_DIR/build/scheduled-sixteen"

"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-sixteen.plsw" scheduled-sixteen

output=$($EMU --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    --speed 0 -n 8000000 --quiet 2>/dev/null \
    | sed '/^Entry point:/d')

# The launcher spawns until the table refuses another child, so this asserts
# the whole table is reachable rather than a hard-coded count: every slot must
# be listed and every slot must be occupied. FULL proves the refusal arrived,
# without which the loop would simply have stopped early and still listed.
expected='SPAWN
1 RUNNABLE
2 RUNNABLE
3 RUNNABLE
4 RUNNABLE
5 RUNNABLE
6 RUNNABLE
7 RUNNABLE
8 RUNNABLE
9 RUNNABLE
10 RUNNABLE
11 RUNNABLE
12 RUNNABLE
13 RUNNABLE
14 RUNNABLE
15 RUNNABLE
16 RUNNABLE
FULL'
if [ "$output" != "$expected" ]; then
    echo "FAIL: the process table did not fill to sixteen runnable slots" >&2
    echo "expected:" >&2
    echo "$expected" >&2
    echo "actual:" >&2
    echo "$output" >&2
    exit 1
fi

echo "PASS: sixteen process slots filled, listed, and further spawn refused"
