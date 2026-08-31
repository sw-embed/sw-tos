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

# The counter has finished by the time this listing is taken, and a slot with
# nothing in it says so: no name, no figures. It used to keep both, so a
# process that had ended still read as one that was there.
released_line='ep=2 name=none state=0 blocked=0 stack=0 statew=0 dispatch=0 yields=0 ipc=0 ttyin=0 ttyout=0'
if ! grep -q "$released_line" <<<"$output"; then
    echo "FAIL: the finished counter's slot was not reported as free" >&2
    echo "$output" >&2
    exit 1
fi

# That its statistics are tracked at all is proved by the shell's own row
# below: the shell is still running when the listing is taken.

# The shell reads a whole line before acting, so it is dispatched once more
# than when it acted on each character as it arrived.
if ! grep -q 'ep=1 name=shell state=1 blocked=0 stack=256 statew=6 dispatch=17 yields=18 ipc=2' <<<"$output"; then
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
