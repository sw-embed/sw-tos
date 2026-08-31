#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/scheduled-stats"
EMU="$ROOT_DIR/scripts/swtos-emu"

"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-shell.plsw" scheduled-stats

output=$($EMU --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    -u '2\nstat 2\nps -l\n' --speed 0 -n 1000000 --quiet 2>/dev/null \
    | sed '/^Entry point:/d')

# The counter has finished by the time this listing is taken. ps -l reports
# what is running, so it must not be there at all: a row of zeroes under a
# name that has gone is what used to make a killed process look present.
if grep -q 'counter' <<<"$output"; then
    echo "FAIL: ps -l listed a process that had finished" >&2
    echo "$output" >&2
    exit 1
fi

# The shell is running, so its own row carries the figures that prove they
# are tracked at all.
if ! grep -q 'shell    ep=1 s=1 b=0 alloc=256/6w d=17 y=18 fp=0 cpu=0 ipc=2' <<<"$output"; then
    echo "FAIL: detailed ps did not report shell scheduling and IPC operations" >&2
    echo "$output" >&2
    exit 1
fi

if [ "$(grep -c "$counter_line" <<<"$output")" -ne 2 ]; then
    echo "FAIL: stat <endpoint> and ps -l did not agree" >&2
    echo "$output" >&2
    exit 1
fi

echo "PASS: process statistics track deterministic dispatch yield IPC and TTY activity"
