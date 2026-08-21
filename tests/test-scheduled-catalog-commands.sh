#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT_DIR/tools/bin/cor24-emu"
OUT_DIR="$ROOT_DIR/build/scheduled-shell"

"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-shell.plsw" scheduled-shell

output=$($EMU --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    -u 'ps\nls\nrun missing\nrun shell\nrun embedded-hello\nrun counter\n0' \
    --speed 0 -n 2000000 --quiet 2>/dev/null \
    | sed '/^Entry point:/d')

for expected in hello counter uptime clock shell embedded-hello embedded-ping E B1 B2 READY BYE; do
    if ! echo "$output" | grep -q "$expected"; then
        echo "FAIL: scheduled catalog command output missing '$expected'" >&2
        echo "$output" >&2
        exit 1
    fi
done

if ! echo "$output" | grep -q 'EREADY'; then
    echo "FAIL: embedded-hello loaded entry did not execute and return" >&2
    echo "$output" >&2
    exit 1
fi

for process_state in '1 RUNNABLE' '2 FREE' '3 FREE'; do
    if ! echo "$output" | grep -q "$process_state"; then
        echo "FAIL: scheduled ps output missing '$process_state'" >&2
        echo "$output" >&2
        exit 1
    fi
done

bad_count=$(echo "$output" | grep -o 'BAD' | wc -l | tr -d ' ')
if [ "$bad_count" -ne 2 ]; then
    echo "FAIL: expected missing program and service name to be rejected" >&2
    echo "$output" >&2
    exit 1
fi

echo "PASS: scheduled shell inspected processes, listed catalog, and ran a program"
