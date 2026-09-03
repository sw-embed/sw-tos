#!/bin/bash
#
# A compile that stops early must be refused, not built.
#
# The PL/SW compiler is a COR24 program running under an instruction budget.
# When it runs out it stops mid-emit, and the half-written assembly it leaves
# behind is not obviously half-written: the build carries on and fails much
# later in the assembler, as an undefined label at whatever line the emit
# happened to stop on. That reads like a fault in the source being compiled,
# and it cost three wrong diagnoses before the cause was found.
#
# The compiler brackets its assembly, and the closing marker is the only thing
# that says it finished. This drives a compile into the wall on purpose and
# requires the marker's absence to be caught.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LINK="$ROOT_DIR/scripts/catalog-spawn-link.sh"
SOURCE="$ROOT_DIR/tests/catalog-shell.plsw"

# Far too few instructions to finish, so the compiler stops part-way through.
if output=$(PLSW_BUDGET=50000000 "$LINK" "$SOURCE" plsw-truncation 2>&1); then
    echo "FAIL: a truncated compile was accepted" >&2
    echo "$output" >&2
    exit 1
fi

if ! grep -q 'did not finish' <<<"$output"; then
    echo "FAIL: a truncated compile was refused for the wrong reason" >&2
    echo "$output" >&2
    exit 1
fi

# And it says what to do about it, since the budget is the usual cause.
if ! grep -q 'PLSW_BUDGET' <<<"$output"; then
    echo "FAIL: the refusal did not name the budget" >&2
    echo "$output" >&2
    exit 1
fi

# The real budget still compiles this source. A test that only proved the
# failure path would pass just as well with a budget nothing can finish in.
if ! "$LINK" "$SOURCE" plsw-truncation >/dev/null 2>&1; then
    echo "FAIL: the configured budget no longer compiles the shell" >&2
    exit 1
fi

if ! grep -q '_swtos_image_end' "$ROOT_DIR/build/plsw-truncation/app.raw.s"; then
    echo "FAIL: a complete compile did not produce complete assembly" >&2
    exit 1
fi

# The check has to be right in both directions, and its first version was not:
# written as `echo "$out" | grep -q marker` under `set -o pipefail`, it reported
# a complete compile as truncated, because grep exits at the first match, echo
# dies with EPIPE, and pipefail takes echo's status. Ten builds in a row is
# cheap insurance against that returning, since the failure was intermittent.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! "$LINK" "$SOURCE" plsw-truncation >/dev/null 2>&1; then
        echo "FAIL: a complete compile was rejected" >&2
        exit 1
    fi
done

echo "PASS: a compile that stops early is refused, and the budget still fits"
