#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT_DIR/scripts/swtos-emu"
OUT_DIR="$ROOT_DIR/build/scheduled-shell"

"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-shell.plsw" scheduled-shell

output=$($EMU --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    -u 'help\ndf\ndu\ndir\nuname\nstat hello\nstat embedded-ping\nstat shell\nstat missing\nps\nls\nrun missing\nrun shell\nrun embedded-hello\nrun counter --tty=new\nps\nrun counter\n' \
    --speed 0 -n 2000000 --quiet 2>/dev/null \
    | sed '/^Entry point:/d')

for expected in hello counter uptime clock shell embedded-hello embedded-ping E B1 B2 READY; do
    if ! echo "$output" | grep -q "$expected"; then
        echo "FAIL: scheduled catalog command output missing '$expected'" >&2
        echo "$output" >&2
        exit 1
    fi
done

for expected in \
    'help ls dir ps run' \
    'df du mem stat uname' \
    'catalog entries=9 images=3 bytes=117' \
    'embedded-hello 36 bytes' \
    'embedded-ping 45 bytes' \
    'cpu-hog 36 bytes' \
    'SWTOS COR24 0.1' \
    'hello kind=program source=resident stack=128 state=0 flags=1 image=0' \
    'embedded-ping kind=program source=embedded stack=128 state=0 flags=0 image=45' \
    'shell kind=service source=resident stack=256 state=6 flags=15 image=0'; do
    if ! echo "$output" | grep -q "$expected"; then
        echo "FAIL: scheduled utility output missing '$expected'" >&2
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
if [ "$bad_count" -ne 3 ]; then
    echo "FAIL: expected missing stat/program and service run to be rejected" >&2
    echo "$output" >&2
    exit 1
fi

echo "PASS: scheduled shell utilities inspected build metadata, processes, and programs"
