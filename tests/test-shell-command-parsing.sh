#!/bin/bash
#
# Shell command-line regression proofs.
#
# Every case here is one a person hit while using the shell, and each was a
# way to lose the prompt entirely or to be told BAD for a line that read
# correctly on screen. They run on the bare emulator because they are about
# the parser, not the frontend: an unanswered prompt shows up as missing
# output either way.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT_DIR/scripts/swtos-emu"
OUT_DIR="$ROOT_DIR/build/scheduled-shell"

"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-shell.plsw" scheduled-shell

run_shell() {
    $EMU --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
        -u "$1" --speed 0 -n 60000000 --quiet 2>/dev/null \
        | sed '/^Entry point:/d'
}

refute() {
    local label="$1" input="$2" needle="$3" output
    output=$(run_shell "$input")
    if printf '%s' "$output" | grep -q -- "$needle"; then
        echo "FAIL: $label (did not expect '$needle')" >&2
        printf '%s\n' "$output" >&2
        exit 1
    fi
}

expect() {
    local label="$1" input="$2" needle="$3" output
    output=$(run_shell "$input")
    if ! printf '%s' "$output" | grep -q -- "$needle"; then
        echo "FAIL: $label (expected '$needle')" >&2
        printf '%s\n' "$output" >&2
        exit 1
    fi
}

# An argument the user never finished used to leave the shell blocked in
# TASK_GETCHAR waiting for the rest of "--tty=new", with no way back.
expect "an unfinished argument does not wedge the prompt" \
    'bg x --\nuname\n' 'SWTOS COR24'

# The flag is gone but old muscle memory and old scripts still type it.
expect "the retired --tty=new flag is still accepted" \
    'bg hello --tty=new\n' 'Hello'

# Backspace used to be stored as part of the name, so every correction
# became a lookup failure. printf puts a real 0x08 in the stream; the
# emulator does not translate a backslash escape.
BS=$(printf '\b')
expect "backspace corrects a mistyped name" \
    "bg helloX${BS}${BS}o\n" 'Hello'

# The command word is read as a line too, so a typo in the command itself is
# correctable. It used to be matched letter by letter as it arrived.
expect "backspace corrects a mistyped command" \
    "halp${BS}${BS}${BS}elp\n" 'help ls dir ps run bg sync kill'

# A correction applies anywhere in the line, not only in the command word.
# Arguments used to be matched as they arrived, so a typo in an option or a
# name was as final as one in the command.
expect "backspace corrects an option" \
    "ps -x${BS}l\n" 'shell    ep=1'
expect "backspace corrects an argument name" \
    "stat hellp${BS}o\n" 'hello kind=program'

# "help NAME" explains one command, which also proves the parser waits for
# the whole line: a parser that acted at the space would print the general
# help before the topic was typed, which is what it used to do.
expect "help explains one command" \
    'help bg\n' 'bg NAME is run'
refute "help does not act at the space" \
    'help bg\n' 'df du mem stat uname'
expect "an unknown help topic is refused" \
    'help nope\n' 'BAD'

# A command is matched on its whole word. "mon" and "mem" are both m and
# three characters long, so matching the first letter and the length ran the
# mem command when a program was asked for.
refute "mon is not mem" \
    'mon\n' 'total='

# A word that is not a command names a program to run, which is what a person
# means by typing it. run and bg say the same thing more explicitly.
expect "a bare program name runs it" \
    'hello\n' 'Hello'
expect "an unknown word is still refused" \
    'nosuch\n' 'BAD'

# A digit is a command like any other: it takes effect on Enter, not on the
# keypress. Reacting to the digit itself made it the one thing that could
# not be taken back. "1x" is therefore a word, not a launch and a keystroke.
expect "a bare menu digit does not act" \
    '1x\n' 'BAD'
expect "a menu digit acts on Enter" \
    '1\nx' 'Hello'

# bg is the ampersand: the program gets its own terminal and the prompt
# stays free. hello sits waiting for a key in its pane, and the shell must
# answer the next command anyway. (Raw input follows the newest child here,
# so the space is what hello is waiting for.)
expect "bg leaves the prompt free" \
    'bg hello\n \nuname\n' 'SWTOS COR24'

# Killing the shell rewinds it. Its slot stays, because the session goes with
# it, but the request is answered rather than refused: an operator asking to
# kill a wedged shell wants it back, not an error.
expect "killing the shell restarts it" \
    'kill 1\n' 'SHELL RESTARTED'

# A line with no endpoint at all is rejected rather than acted on.
expect "kill without an endpoint is rejected" \
    'kill nothing\n' 'BAD'

# The ep= spelling is proved against a live process in the framed
# debugger-kill recipe; a bare run cannot, because raw input follows the
# spawned child rather than staying with this shell.
echo "PASS: shell command parsing survives unfinished arguments and corrections"
