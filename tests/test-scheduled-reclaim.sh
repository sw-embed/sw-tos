#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT_DIR/tools/bin/cor24-emu"
OUT_DIR="$ROOT_DIR/build/scheduled-shell"
LAUNCHES=20

"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-shell.plsw" scheduled-shell

input=''
for ((i = 0; i < LAUNCHES; i++)); do
    input="${input}run embedded-hello\\n"
    input="${input}run counter\\n"
done
input="${input}0"

output=$($EMU --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    -u "$input" --speed 0 -n 8000000 --quiet 2>/dev/null \
    | sed '/^Entry point:/d')

for marker in B1 B2 READY BYE; do
    if ! echo "$output" | grep -q "$marker"; then
        echo "FAIL: reclaim stress output missing '$marker'" >&2
        echo "$output" >&2
        exit 1
    fi
done

ready_count=$(echo "$output" | grep -o 'READY' | wc -l | tr -d ' ')
b1_count=$(echo "$output" | grep -o 'B1' | wc -l | tr -d ' ')
b2_count=$(echo "$output" | grep -o 'B2' | wc -l | tr -d ' ')
embedded_count=$(echo "$output" | grep -o 'EREADY' | wc -l | tr -d ' ')
expected_ready=$((LAUNCHES * 2))
if [ "$ready_count" -ne "$expected_ready" ] || \
        [ "$b1_count" -ne "$LAUNCHES" ] || \
        [ "$b2_count" -ne "$LAUNCHES" ] || \
        [ "$embedded_count" -ne "$LAUNCHES" ]; then
    echo "FAIL: expected $LAUNCHES resident/embedded cycles; got READY=$ready_count E=$embedded_count B1=$b1_count B2=$b2_count" >&2
    echo "$output" >&2
    exit 1
fi

echo "PASS: $LAUNCHES resident/embedded cycles reclaimed the EBR arena"
