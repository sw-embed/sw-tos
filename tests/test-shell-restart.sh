#!/bin/bash
#
# The shell is the one process that cannot be killed: the session ends with
# it. So it can be restarted instead, and this checks that the way out exists
# from each state an operator can be stuck in.
#
# FF 04 is the request. It is read by the UART interrupt handler rather than
# by the shell, because the case it exists for is a shell that is no longer
# reading anything.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT_DIR/scripts/swtos-emu"
OUT_DIR="$ROOT_DIR/build/scheduled-shell"

"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-shell.plsw" scheduled-shell >/dev/null

run() {
    $EMU --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
        -u "$1" --speed 0 -n 4000000 --quiet 2>/dev/null \
        | sed '/^Entry point:/d'
}

check() {
    local name="$1" input="$2" pattern="$3" output
    output=$(run "$input")
    if ! grep -q "$pattern" <<<"$output"; then
        echo "FAIL: $name: no '$pattern'" >&2
        echo "$output" >&2
        exit 1
    fi
}

count_prompts() {
    grep -c 'Choice:' <<<"$1" || true
}

check "the escape restarts a shell sitting at its prompt" \
    '\xFF\x04' 'SHELL RESTARTED'

check "a restarted shell offers its menu again" \
    '\xFF\x04' 'MENU 1=Hello'

check "the shell accepts kill 1 rather than refusing it" \
    'kill 1\n' 'SHELL RESTARTED'

check "a restarted shell still runs commands" \
    '\xFF\x04mem\n' 'total='

check "the ISR escape requests a full warm reboot" \
    '\xFF\x05' 'SYSTEM REBOOTED'

check "the typed command requests the same warm reboot" \
    'reboot\n' 'SYSTEM REBOOTED'

# Twice over: a restart that leaked its stack or its private state would fail
# the second time, and this is the failure it would be reached for repeatedly.
output=$(run '\xFF\x04\xFF\x04\xFF\x04')
restarts=$(grep -c 'SHELL RESTARTED' <<<"$output" || true)
if [ "$restarts" -lt 3 ]; then
    echo "FAIL: expected three restarts, saw $restarts" >&2
    echo "$output" >&2
    exit 1
fi

echo "PASS: the shell restarts on request and keeps working afterwards"
