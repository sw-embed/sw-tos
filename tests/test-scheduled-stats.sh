#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/scheduled-stats"
EMU="$ROOT_DIR/tools/bin/cor24-emu"

"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-shell.plsw" scheduled-stats

output=$($EMU --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    -u '2stat 2\nps -l\n' --speed 0 -n 1000000 --quiet 2>/dev/null \
    | sed '/^Entry point:/d')

counter_line='ep=2 name=counter state=0 blocked=0 stack=192 statew=1 dispatch=3 yields=2 ipc=0 ttyin=0 ttyout=6'
if ! grep -q "$counter_line" <<<"$output"; then
    echo "FAIL: counter activity snapshot did not match deterministic transitions" >&2
    echo "$output" >&2
    exit 1
fi

if ! grep -q 'ep=1 name=shell state=1 blocked=0 stack=256 statew=6 dispatch=2 yields=3 ipc=2' <<<"$output"; then
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
