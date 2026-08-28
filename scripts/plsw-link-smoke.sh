#!/bin/bash
# Compile two independent PL/SW modules, link them, and verify execution.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TOOL_DIR="$ROOT_DIR/tools/bin"
PLSW_LGO="$ROOT_DIR/tools/plsw.lgo"
COR24_ASM="$TOOL_DIR/cor24-asm"
COR24_EMU="$ROOT_DIR/scripts/swtos-emu"
LINK24="$TOOL_DIR/link24"
META_GEN="$TOOL_DIR/meta-gen"
OUT_DIR="$ROOT_DIR/build/multimodule"
MODULES=(multimodule-main multimodule-lib)
SOURCES=(
    "$ROOT_DIR/tests/multimodule-main.plsw"
    "$ROOT_DIR/tests/multimodule-lib.plsw"
)

for tool in "$COR24_ASM" "$COR24_EMU" "$LINK24" "$META_GEN"; do
    if [ ! -x "$tool" ]; then
        echo "Error: required tool not found: $tool" >&2
        exit 1
    fi
done
if [ ! -f "$PLSW_LGO" ]; then
    echo "Error: PL/SW compiler not found: $PLSW_LGO" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

compile_module() {
    local source="$1"
    local output="$2"
    local scratch
    local uart_input
    local compiler_output
    scratch=$(mktemp -d /tmp/swtos-link-XXXXXX)
    uart_input="$scratch/input.bin"

    {
        printf 'c\n'
        sed -n 'p' "$source"
        printf '\x04'
    } > "$uart_input"

    compiler_output=$($COR24_EMU --lgo "$PLSW_LGO" \
        --uart-file "$uart_input" --quiet --speed 0 \
        -n 200000000 -t 120 2>&1)
    rm -rf "$scratch"

    if echo "$compiler_output" | grep -q "compilation failed\|COMPILE ERROR\|ERROR:"; then
        echo "Compilation failed for $source:" >&2
        echo "$compiler_output" >&2
        exit 1
    fi

    echo "$compiler_output" | sed -n \
        '/--- generated assembly ---/,/--- end assembly ---/{/--- generated assembly ---/d;/--- end assembly ---/d;p;}' \
        > "$output"
    if [ ! -s "$output" ]; then
        echo "Error: compiler produced no assembly for $source" >&2
        exit 1
    fi
}

sizes=()
for i in "${!MODULES[@]}"; do
    module="${MODULES[$i]}"
    echo "=== Compiling $module ===" >&2
    compile_module "${SOURCES[$i]}" "$OUT_DIR/$module.raw.s"
    "$META_GEN" prep "$OUT_DIR/$module.raw.s" \
        -o "$OUT_DIR/$module.s" --syms "$OUT_DIR/$module.syms"
    "$COR24_ASM" "$OUT_DIR/$module.s" \
        -o "$OUT_DIR/$module.lgo" \
        --bin "$OUT_DIR/$module.bin" \
        --listing "$OUT_DIR/$module.lst"
    sizes+=("$(wc -c < "$OUT_DIR/$module.bin" | tr -d ' ')")
    "$META_GEN" emit "$OUT_DIR/$module.lst" \
        --syms "$OUT_DIR/$module.syms" --module "$module" \
        -o "$OUT_DIR/$module.meta"
done

base=0
for i in "${!MODULES[@]}"; do
    module="${MODULES[$i]}"
    "$COR24_ASM" "$OUT_DIR/$module.s" --base-addr "$base" \
        -o "$OUT_DIR/$module.lgo" \
        --bin "$OUT_DIR/$module.bin" \
        --listing "$OUT_DIR/$module.lst"
    base=$((base + sizes[i]))
done

"$LINK24" --entry multimodule-main --dir "$OUT_DIR" \
    --map "$OUT_DIR/program.map" \
    multimodule-main multimodule-lib -o "$OUT_DIR/program.bin"

output=$($COR24_EMU --load-binary "$OUT_DIR/program.bin@0" \
    --entry 0 --speed 0 -n 1000000 --quiet 2>/dev/null \
    | sed '/^Entry point:/d')
if [ "$output" != "LINKED" ]; then
    echo "FAIL: expected LINKED, got '$output'" >&2
    exit 1
fi

echo "PASS: separate PL/SW modules linked and ran: $output"
