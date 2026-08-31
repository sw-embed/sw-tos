#!/bin/bash
#
# Running a program without a process of its own.
#
# There are sixteen slots. When they are all taken, refusing to start anything
# was the honest answer only while there was nowhere else to run it: a
# resident program can run in the shell's own context, on the shell's stack,
# for as long as it takes to finish. The prompt is gone until it does.
#
# The bargain is that nothing can preempt it -- it is the shell, and the shell
# is not preemptible -- so this is only safe because the restart escape exists.
# See test-shell-restart.sh.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT_DIR/scripts/swtos-emu"
OUT_DIR="$ROOT_DIR/build/scheduled-shell"

"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-shell.plsw" scheduled-shell >/dev/null

run() {
    $EMU --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
        -u "$1" --speed 0 -n "${2:-20000000}" --quiet 2>/dev/null \
        | sed '/^Entry point:/d'
}

fail() { echo "FAIL: $1" >&2; echo "$2" >&2; exit 1; }

expect() {
    local name="$1" input="$2" pattern="$3" output
    output=$(run "$input")
    grep -q "$pattern" <<<"$output" || fail "$name: no '$pattern'" "$output"
}

refute() {
    local name="$1" input="$2" pattern="$3" output
    output=$(run "$input")
    grep -q "$pattern" <<<"$output" && fail "$name: found '$pattern'" "$output"
    return 0
}

# The counter steps twice and exits. Run here it prints under the shell's own
# endpoint, which is A, and the shell survives its TASK_EXIT.
expect "a synchronous program runs"        'sync counter\n' 'A1'
expect "and finishes"                      'sync counter\n' 'A2'
expect "and the prompt comes back"         'sync counter\nmem\n' 'total='

# No process was made. A run that quietly took a slot would be the bug this
# exists to avoid.
expect "no slot is consumed"               'sync counter\nmem\n' 'slots=1/16'

# An embedded program has to be loaded into memory owned by a process, and a
# process is the thing there is none of.
expect "an embedded program is refused"    'sync cpu-hog\n' 'needs a slot of its own'
expect "an unknown name is refused"        'sync nosuch\n' 'BAD'
expect "a bare sync is refused"            'sync\n' 'BAD'

# And the reason it exists: with every slot taken, a launch says so and runs
# it here rather than failing.
full=$(printf 'bg clock\\n%.0s' $(seq 15))
output=$(run "${full}bg counter\nmem\n" 60000000)
grep -q 'no free slot: running it here' <<<"$output" ||
    fail "a full table did not fall back" "$output"
grep -q '^A1$' <<<"$output" ||
    fail "the fallback did not run the program" "$output"
grep -q 'slots=16/16' <<<"$output" ||
    fail "the table was not actually full" "$output"

# With a slot free it spawns, as it always did: the fallback is a fallback.
refute "a free table still spawns"         'bg counter\n' 'no free slot'

# The bargain, made good. The monitor never finishes, so run here it owns the
# shell forever -- and the restart escape takes it back, leaving no process
# behind, because there was never a process.
output=$(run 'sync mon\n\xFF\x04mem\n' 30000000)
grep -q 'SHELL RESTARTED' <<<"$output" ||
    fail "could not escape a synchronous program that does not finish" "$output"
grep -q 'slots=1/16' <<<"$output" ||
    fail "escaping left something behind" "$output"

echo "PASS: a program runs in the shell when it has nowhere else to run"
