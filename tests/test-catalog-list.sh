#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT_DIR/tools/bin/cor24-emu"

output=$($EMU --lgo "$ROOT_DIR/build/system.lgo" \
    -u 'ls\n' --speed 0 -n 1500000 --quiet 2>/dev/null)

for name in hello counter clock shell; do
    if ! echo "$output" | grep -q "^${name}$"; then
        echo "FAIL: catalog listing missing '$name'" >&2
        echo "$output" >&2
        exit 1
    fi
done

if echo "$output" | grep -q 'Invalid choice'; then
    echo "FAIL: ls leaked command bytes into the menu" >&2
    exit 1
fi

echo "PASS: shell ls enumerated all generated catalog descriptors"
