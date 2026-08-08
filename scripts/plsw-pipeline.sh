#!/bin/bash
# plsw-pipeline.sh -- Compile a .plsw file using the PL/SW compiler on the
# emulator, assemble the generated .s, and optionally run it.
#
# Usage: ./scripts/plsw-pipeline.sh [include.msw ...] program.plsw [--run|--dump]
#
# Uses --uart-file to feed source to the compiler (avoids -u escape handling
# bugs with the FILE:/SOURCE: protocol).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TOOLDIR="$ROOT_DIR/tools"
PLSW_LGO="$TOOLDIR/plsw.lgo"
COR24ASM="$TOOLDIR/bin/cor24-asm"
COR24EMU="$TOOLDIR/bin/cor24-emu"

if [ ! -f "$PLSW_LGO" ]; then
    echo "Error: $PLSW_LGO not found." >&2
    exit 1
fi

if [ $# -lt 1 ]; then
    echo "Usage: $0 [include.msw ...] program.plsw [--run|--dump]" >&2
    exit 1
fi

MACROS=()
MAIN=""
RUN_MODE=""
for f in "$@"; do
    case "$f" in
        --run|--dump) RUN_MODE="$f" ;;
        *.msw) MACROS+=("$f") ;;
        *.plsw) MAIN="$f" ;;
        *) echo "Error: unknown file type: $f" >&2; exit 1 ;;
    esac
done

if [ -z "$MAIN" ]; then
    echo "Error: no .plsw file specified" >&2
    exit 1
fi

BASENAME=$(basename "$MAIN" .plsw)
OUTDIR="$ROOT_DIR/build"
mkdir -p "$OUTDIR"

# Build UART input file with FILE:/SOURCE: protocol
SCRATCH=$(mktemp -d /tmp/plsw-XXXXXX)
trap "rm -rf $SCRATCH" EXIT
UART_INPUT="$SCRATCH/input.bin"

{
    printf 'c\n'
    if [ ${#MACROS[@]} -gt 0 ]; then
        for m in "${MACROS[@]}"; do
            NAME=$(basename "$m" .msw)
            printf 'FILE:%s\n' "$NAME"
            cat "$m"
            printf '\x1e'
        done
        printf 'SOURCE:\n'
    fi
    cat "$MAIN"
    printf '\x04'
} > "$UART_INPUT"

# Compile: feed source to PL/SW compiler running on emulator via --uart-file
echo "=== Compiling $BASENAME ===" >&2
COMPILER_OUT=$($COR24EMU --lgo "$PLSW_LGO" --uart-file "$UART_INPUT" \
    --quiet --speed 0 -n 200000000 -t 120 2>&1)

UART_OUT="$COMPILER_OUT"

if echo "$UART_OUT" | grep -q "compilation failed\|COMPILE ERROR\|ERROR:"; then
    echo "Compilation failed:" >&2
    echo "$UART_OUT" | grep -E "ERROR:|failed" >&2
    echo "" >&2
    echo "Full compiler output:" >&2
    echo "$UART_OUT" >&2
    exit 1
fi

# Extract assembly between markers
START_MARKER="--- generated assembly ---"
END_MARKER="--- end assembly ---"
ASM=$(echo "$UART_OUT" | sed -n "/$START_MARKER/,/$END_MARKER/{/$START_MARKER/d;/$END_MARKER/d;p;}")

if [ -z "$ASM" ]; then
    echo "Error: no assembly output found in compiler output" >&2
    echo "Compiler UART output (last 30 lines):" >&2
    echo "$UART_OUT" | tail -30 >&2
    exit 1
fi

OUT_S="$OUTDIR/${BASENAME}.s"
OUT_LGO="$OUTDIR/${BASENAME}.lgo"

echo "$ASM" > "$OUT_S"
ASM_LINES=$(echo "$ASM" | wc -l | tr -d ' ')
echo "Assembly: $ASM_LINES lines -> $OUT_S" >&2

# Assemble
$COR24ASM "$OUT_S" -o "$OUT_LGO"
echo "Binary: $OUT_LGO" >&2

if [ "$RUN_MODE" = "--run" ]; then
    echo "=== Running ===" >&2
    RUN_OUT=$($COR24EMU --lgo "$OUT_LGO" -n -1 --speed 0 --quiet 2>&1)
    if [ -n "$RUN_OUT" ]; then
        echo "$RUN_OUT"
    fi
elif [ "$RUN_MODE" = "--dump" ]; then
    echo "=== Dump ===" >&2
    $COR24EMU --lgo "$OUT_LGO" -n -1 --speed 0 --dump > "$OUTDIR/${BASENAME}-dump.txt" 2>&1
    echo "Dump: $OUTDIR/${BASENAME}-dump.txt" >&2
fi
