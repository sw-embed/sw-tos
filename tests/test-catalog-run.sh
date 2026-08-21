#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT_DIR/tools/bin/cor24-emu"

counter_output=$($EMU --lgo "$ROOT_DIR/build/system.lgo" \
    -u 'run counter\n' --speed 0 -n 3000000 --quiet 2>/dev/null)
if ! echo "$counter_output" | grep -q 'Count:'; then
    echo "FAIL: run counter did not dispatch the catalog entry" >&2
    echo "$counter_output" >&2
    exit 1
fi
if echo "$counter_output" | grep -q 'Invalid choice'; then
    echo "FAIL: run counter leaked command bytes into the menu" >&2
    exit 1
fi

missing_output=$($EMU --lgo "$ROOT_DIR/build/system.lgo" \
    -u 'run embedded-hello\nrun missing\n' --speed 0 -n 1000000 --quiet 2>/dev/null)
not_found_count=$(echo "$missing_output" | grep -o 'Program not found' | wc -l | tr -d ' ')
if [ "$not_found_count" -ne 2 ]; then
    echo "FAIL: compatibility shell did not reject embedded and missing names" >&2
    echo "$missing_output" >&2
    exit 1
fi

echo "PASS: shell run command dispatched and rejected catalog names"
