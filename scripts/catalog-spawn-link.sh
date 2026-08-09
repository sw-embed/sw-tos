#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOL_DIR="$ROOT_DIR/tools/bin"
PLSW_SOURCE="${1:-$ROOT_DIR/tests/catalog-counter.plsw}"
BUILD_NAME="${2:-catalog-spawn}"
OUT_DIR="$ROOT_DIR/build/$BUILD_NAME"
ASM="$TOOL_DIR/cor24-asm"
EMU="$TOOL_DIR/cor24-emu"
META_GEN="$TOOL_DIR/meta-gen"
LINK="$TOOL_DIR/link24"
PLSW="$ROOT_DIR/tools/plsw.lgo"
MODULES=(kernel app)

mkdir -p "$OUT_DIR"
python3 "$ROOT_DIR/scripts/generate-catalog.py"
scratch=$(mktemp -d /tmp/swtos-catalog-spawn-XXXXXX)
trap 'rm -rf "$scratch"' EXIT
{
    printf 'c\n'
    sed -n 'p' "$PLSW_SOURCE"
    printf '\x04'
} > "$scratch/input.bin"

compiler_output=$($EMU --lgo "$PLSW" --uart-file "$scratch/input.bin" \
    --quiet --speed 0 -n 200000000 -t 120 2>&1)
if echo "$compiler_output" | grep -q 'compilation failed\|COMPILE ERROR\|ERROR:'; then
    echo "PL/SW task compilation failed:" >&2
    echo "$compiler_output" >&2
    exit 1
fi
echo "$compiler_output" | sed -n \
    '/--- generated assembly ---/,/--- end assembly ---/{/--- generated assembly ---/d;/--- end assembly ---/d;p;}' \
    > "$OUT_DIR/app.raw.s"
cp "$ROOT_DIR/hal/cor24/catalog-spawn.s" "$OUT_DIR/kernel.raw.s"
sed -n 'p' "$ROOT_DIR/hal/cor24/catalog_generated.s" >> "$OUT_DIR/kernel.raw.s"

sizes=()
for module in "${MODULES[@]}"; do
    "$META_GEN" prep "$OUT_DIR/$module.raw.s" \
        -o "$OUT_DIR/$module.s" --syms "$OUT_DIR/$module.syms"
    "$ASM" "$OUT_DIR/$module.s" -o "$OUT_DIR/$module.lgo" \
        --bin "$OUT_DIR/$module.bin" --listing "$OUT_DIR/$module.lst"
    "$META_GEN" emit "$OUT_DIR/$module.lst" --syms "$OUT_DIR/$module.syms" \
        --module "$module" -o "$OUT_DIR/$module.meta"
    sizes+=("$(wc -c < "$OUT_DIR/$module.bin" | tr -d ' ')")
done

base=0
for i in "${!MODULES[@]}"; do
    module="${MODULES[$i]}"
    "$ASM" "$OUT_DIR/$module.s" --base-addr "$base" \
        -o "$OUT_DIR/$module.lgo" --bin "$OUT_DIR/$module.bin" \
        --listing "$OUT_DIR/$module.lst"
    base=$((base + sizes[i]))
done

"$LINK" --entry kernel --dir "$OUT_DIR" \
    --map "$OUT_DIR/program.map" kernel app \
    -o "$OUT_DIR/program.bin"
