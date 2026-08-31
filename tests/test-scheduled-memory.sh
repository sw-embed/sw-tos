#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT_DIR/scripts/swtos-emu"
OUT_DIR="$ROOT_DIR/build/scheduled-shell"
FAIL_BUILD="$ROOT_DIR/build/scheduled-memory-exhaustion"
FAIL_MANIFEST="$FAIL_BUILD/catalog.toml"

"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-shell.plsw" scheduled-shell

output=$($EMU --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    -u 'mem\nmem -p\n5\nmem\nmem -r\nmem\n' \
    --speed 0 -n 4000000 --quiet 2>/dev/null \
    | sed '/^Entry point:/d')

summary_count=$(grep -c 'total=1048576 image=' <<<"$output")
if [ "$summary_count" -ne 3 ]; then
    echo "FAIL: expected three complete mem summaries, saw $summary_count" >&2
    echo "$output" >&2
    exit 1
fi

for expected in \
    'arena=256 peak=256' \
    'arena=256 peak=640' \
    'kstack=7' \
    'failures=0 slots=1/16' \
    'ep=1 status=1 stack=256 state=6 total=262' \
    'ep=2 status=0 stack=0 state=0 total=0' \
    'ep=3 status=0 stack=0 state=0 total=0' \
    'mem counters reset'; do
    if ! grep -q "$expected" <<<"$output"; then
        echo "FAIL: memory output missing '$expected'" >&2
        echo "$output" >&2
        exit 1
    fi
done

if [ "$(grep -c 'arena=256 peak=256' <<<"$output")" -ne 2 ]; then
    echo "FAIL: mem -r did not reset the arena high-water mark" >&2
    echo "$output" >&2
    exit 1
fi

mkdir -p "$FAIL_BUILD"
# Enlarge only the first 192-word stack request. GNU sed spells this
# 0,/re/s//../; BSD sed rejects a zero line address and silently copies the
# manifest through unchanged, leaving nothing oversized to reject. awk is the
# portable way to bound the substitution to the first match.
# The stack region is 64 KB of SRAM, so exhausting it needs a request past
# its 21845-word capacity; 1000 words fitted only in the former 3 KB EBR arena.
awk '!done && sub(/stack_words = 192/, "stack_words = 30000") { done = 1 } { print }' \
    "$ROOT_DIR/catalog/catalog.toml" > "$FAIL_MANIFEST"
"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-shell.plsw" scheduled-memory-exhaustion memory \
    "$FAIL_MANIFEST"

failure_output=$($EMU --load-binary "$FAIL_BUILD/program.bin@0" --entry 0 \
    -u 'run counter\nmem\n' --speed 0 -n 2000000 --quiet 2>/dev/null \
    | sed '/^Entry point:/d')

if ! grep -q 'ERROR' <<<"$failure_output"; then
    echo "FAIL: oversized process allocation was not rejected" >&2
    echo "$failure_output" >&2
    exit 1
fi
# The stack-region peak no longer moves on a failed spawn: the state block it
# rolls back is allocated from the SRAM heap, which mem does not yet report.
if ! grep -q 'arena=256 peak=256.*failures=1 slots=1/16' <<<"$failure_output"; then
    echo "FAIL: failed spawn did not report the failure" >&2
    echo "$failure_output" >&2
    exit 1
fi

echo "PASS: mem reports image arena process stack peaks reset and exhaustion"
