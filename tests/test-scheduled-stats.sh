#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/scheduled-stats"
EMU="$ROOT_DIR/scripts/swtos-emu"

"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-shell.plsw" scheduled-stats

# bg, not the menu: the menu runs its programs in the shell itself now, and a
# program that never becomes a process exercises none of the spawn accounting
# this is here to measure.
output=$($EMU --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    -u 'bg counter\nstat 2\nps -l\n' --speed 0 -n 2000000 --quiet 2>/dev/null \
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
if ! grep -q 'shell    ep=1 s=1 b=0 alloc=256/6w d=24 y=25 fp=0 cpu=0 ipc=1' <<<"$output"; then
    echo "FAIL: detailed ps did not report shell scheduling and IPC operations" >&2
    echo "$output" >&2
    exit 1
fi

# The slot the counter used reports nothing of it. This never ran: it compared
# against a variable that was never assigned, so the unbound name failed inside
# the command substitution, the test that followed complained about an empty
# integer, and the script carried on to pass. What it should have checked is
# that a released slot keeps none of its last tenant's figures.
if ! grep -q 'ep=2 name=none state=0 blocked=0 stack=0 statew=0 dispatch=0 yields=0 ipc=0 ttyin=0 ttyout=0' <<<"$output"; then
    echo "FAIL: a released slot still reported its last tenant" >&2
    echo "$output" >&2
    exit 1
fi

echo "PASS: process statistics track deterministic dispatch yield IPC and TTY activity"
