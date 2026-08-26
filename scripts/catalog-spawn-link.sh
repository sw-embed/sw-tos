#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOL_DIR="$ROOT_DIR/tools/bin"
PLSW_SOURCE="${1:-$ROOT_DIR/tests/catalog-counter.plsw}"
BUILD_NAME="${2:-catalog-spawn}"
PROVIDER_MODE="${3:-memory}"
CATALOG_MANIFEST="${4:-$ROOT_DIR/catalog/catalog.toml}"
OUT_DIR="$ROOT_DIR/build/$BUILD_NAME"
ASM="$TOOL_DIR/cor24-asm"
EMU="$TOOL_DIR/cor24-emu"
META_GEN="$TOOL_DIR/meta-gen"
LINK="$TOOL_DIR/link24"
PLSW="$ROOT_DIR/tools/plsw.lgo"
MODULES=(kernel protocol app)

mkdir -p "$OUT_DIR"
if [ "$CATALOG_MANIFEST" = "$ROOT_DIR/catalog/catalog.toml" ]; then
    python3 "$ROOT_DIR/scripts/generate-catalog.py"
    SCHEDULED_CATALOG="$ROOT_DIR/hal/cor24/catalog_generated.s"
    SHELL_CATALOG="$ROOT_DIR/include/shell_catalog_generated.msw"
else
    SCHEDULED_CATALOG="$OUT_DIR/catalog_generated.s"
    python3 "$ROOT_DIR/scripts/generate-catalog.py" \
        --manifest "$CATALOG_MANIFEST" \
        --output "$OUT_DIR/catalog_generated.msw" \
        --scheduled-output "$SCHEDULED_CATALOG" \
        --shell-output "$OUT_DIR/shell_catalog_generated.msw"
    SHELL_CATALOG="$OUT_DIR/shell_catalog_generated.msw"
fi
scratch=$(mktemp -d /tmp/swtos-catalog-spawn-XXXXXX)
trap 'rm -rf "$scratch"' EXIT
{
    printf 'c\n'
    if [ "$(basename "$PLSW_SOURCE")" = "catalog-shell.plsw" ]; then
        sed -n 'p' "$SHELL_CATALOG"
    fi
    sed -n 'p' "$PLSW_SOURCE"
    printf '\x04'
} > "$scratch/input.bin"

compiler_output=$($EMU --lgo "$PLSW" --uart-file "$scratch/input.bin" \
    --quiet --speed 0 -n 500000000 -t 120 2>&1)
if echo "$compiler_output" | grep -q 'compilation failed\|COMPILE ERROR\|ERROR:'; then
    echo "PL/SW task compilation failed:" >&2
    echo "$compiler_output" >&2
    exit 1
fi
echo "$compiler_output" | sed -n \
    '/--- generated assembly ---/,/--- end assembly ---/{/--- generated assembly ---/d;/--- end assembly ---/d;p;}' \
    > "$OUT_DIR/app.raw.s"
printf '%s\n' \
    '        .globl  _swtos_image_end' \
    '_swtos_image_end:' \
    '        .byte   0' >> "$OUT_DIR/app.raw.s"
cp "$ROOT_DIR/hal/cor24/catalog-spawn.s" "$OUT_DIR/kernel.raw.s"
cp "$ROOT_DIR/hal/cor24/protocol-v1.s" "$OUT_DIR/protocol.raw.s"
sed -n 'p' "$ROOT_DIR/hal/cor24/i2c.s" >> "$OUT_DIR/kernel.raw.s"
sed -n 'p' "$ROOT_DIR/hal/cor24/spi.s" >> "$OUT_DIR/kernel.raw.s"
sed -n 'p' "$SCHEDULED_CATALOG" >> "$OUT_DIR/kernel.raw.s"
while IFS=$'\t' read -r image_name image_manifest; do
    image_label="${image_name//-/_}"
    image_asm="$OUT_DIR/$image_name.s"
    python3 "$ROOT_DIR/scripts/cor24-image.py" emit-asm \
        "$ROOT_DIR/$image_manifest" "$image_asm" \
        --label "_embedded_${image_label}_image"
    sed -n 'p' "$image_asm" >> "$OUT_DIR/kernel.raw.s"
done < <(python3 "$ROOT_DIR/scripts/generate-catalog.py" \
    --manifest "$CATALOG_MANIFEST" --list-images)
python3 "$ROOT_DIR/scripts/configure-provider.py" \
    "$OUT_DIR/kernel.raw.s" "$PROVIDER_MODE"

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
    --map "$OUT_DIR/program.map" kernel protocol app \
    -o "$OUT_DIR/program.bin"
python3 "$ROOT_DIR/scripts/generate-debug-info.py" \
    --binary "$OUT_DIR/program.bin" --map "$OUT_DIR/program.map" \
    --listing "$OUT_DIR/kernel.lst" --listing "$OUT_DIR/protocol.lst" \
    --listing "$OUT_DIR/app.lst" --output "$OUT_DIR/program.debug.json"
"$ROOT_DIR/scripts/cor24-bin-to-lgo.py" \
    "$OUT_DIR/program.bin" "$OUT_DIR/program.lgo" \
    --load-address 0 --entry-address 0
