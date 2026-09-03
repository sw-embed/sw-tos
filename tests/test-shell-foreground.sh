#!/bin/bash
#
# The prompt keeps the terminal.
#
# On a bare UART there is one keyboard, and every process that exits used to
# hand it to whichever of the first two child slots was occupied. The monitor
# lives in that slot now, and a monitor blocks reading its own terminal --
# waiting for clock ticks, not for a person -- so the keyboard went to it and
# the prompt never saw another keystroke. Everything after the first command
# was swallowed.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT_DIR/scripts/swtos-emu"
OUT_DIR="$ROOT_DIR/build/scheduled-shell"

"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-shell.plsw" scheduled-shell >/dev/null

run() {
    $EMU --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
        -u "$1" --speed 0 -n "${2:-40000000}" --quiet 2>/dev/null \
        | sed '/^Entry point:/d'
}

fail() {
    echo "FAIL: $1" >&2
    echo "$2" >&2
    exit 1
}

# A background launch does not take the keyboard with it.
output=$(run 'mon\nmem\n')
grep -q 'total=' <<<"$output" ||
    fail "the prompt lost the keyboard to a background program" "$output"

# Nor does a foreground command that finishes, with that program still running.
output=$(run 'mon\n5\nmem\n')
grep -q 'total=' <<<"$output" ||
    fail "the prompt lost the keyboard when a child exited" "$output"

# The menu runs its programs in the shell itself. It used to start one as a
# process and wait for it, which put its output in a pane of its own while the
# shell that waited for it owned another: typing reached the shell, which was
# not reading, so a kill aimed at the pane that was scrolling did nothing, and
# for a clock or an uptime the wait never ended at all.
#
# One pane, one thing typing reaches, and nothing in the process table to kill
# because nothing was put there.
output=$(run '3\n\x1bmem\n')
grep -q 'Uptime' <<<"$output" ||
    fail "the menu did not run uptime" "$output"
grep -q 'slots=1/16' <<<"$output" ||
    fail "a menu program took a process slot" "$output"
grep -q 'total=' <<<"$output" ||
    fail "Escape did not return the prompt" "$output"

# And it is a running program, not merely a started one: the time broadcast
# finds a clock or an uptime by the program its slot names, so a shell that
# went on naming itself was never sent a tick.
output=$(run '3\n\xFF\x01\xF4\x01\x00\xFF\x01\x58\x02\x00\x1bmem\n')
grep -q '00:05' <<<"$output" ||
    fail "a menu uptime was never sent the time" "$output"

output=$(run '1\nx\nmem\n')
grep -q 'Press a key here to exit' <<<"$output" ||
    fail "the menu did not run Hello in the shell" "$output"

# A program running here owns the shell until it ends, so the way out is said
# before it starts rather than left to be guessed at.
grep -q 'Ctrl-\[ to end' <<<"$output" ||
    fail "starting a foreground program did not say how to end it" "$output"

# The same command twice is the same command twice. The counters exit on their
# second step, so a stale or shared state word shows up immediately as a run
# that does not stop where the first one did.
output=$(run 'mon\n5\n5\n5\nmem\n' 80000000)
runs=$(grep -o 'READY' <<<"$output" | wc -l | tr -d ' ')
# One for the monitor, one for each run of the demo.
[ "$runs" -eq 4 ] ||
    fail "expected four completed launches, saw $runs" "$output"
# A worker step is a slot letter and a step number on a line of its own; the
# prompt shares a line with whatever answered it, so take that off first.
steps=$(sed 's/^# //' <<<"$output")
first=$(grep -c '^[A-P]1$' <<<"$steps" || true)
[ "$first" -eq 6 ] ||
    fail "expected six first steps across three runs, saw $first" "$output"
second=$(grep -c '^[A-P]2$' <<<"$steps" || true)
[ "$second" -eq 6 ] ||
    fail "expected six second steps across three runs, saw $second" "$output"
grep -qE '^[A-P][3-9]$' <<<"$steps" &&
    fail "a worker ran past the step it exits on" "$output"

# Slots are reused rather than consumed: three runs of two workers each, and
# the table still reports the shell and the monitor.
grep -q 'slots=2/16' <<<"$output" ||
    fail "the process table did not come back to two" "$output"

echo "PASS: the prompt keeps the terminal, and repeated launches repeat"
