#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/provider-config"
mkdir -p "$OUT_DIR"

for provider in memory composite-spi composite-sd; do
    fixture="$OUT_DIR/$provider.s"
    cp "$ROOT_DIR/hal/cor24/catalog-spawn.s" "$fixture"
    python3 "$ROOT_DIR/scripts/configure-provider.py" "$fixture" "$provider" >/dev/null
done

grep -q '\.word   _memory_image_provider' "$OUT_DIR/memory.s"
grep -q '\.word   _composite_image_provider' "$OUT_DIR/composite-spi.s"
grep -q '\.word   _composite_prepare_spi' "$OUT_DIR/composite-spi.s"
grep -q '\.word   _composite_external_spi_read' "$OUT_DIR/composite-spi.s"
grep -q '\.word   _composite_image_provider' "$OUT_DIR/composite-sd.s"
grep -q '\.word   _composite_prepare_sd' "$OUT_DIR/composite-sd.s"
grep -q '\.word   _composite_external_sd_read' "$OUT_DIR/composite-sd.s"

if python3 "$ROOT_DIR/scripts/configure-provider.py" \
    "$OUT_DIR/memory.s" missing >"$OUT_DIR/missing.log" 2>&1; then
    echo "FAIL: unknown provider configuration was accepted" >&2
    exit 1
fi

echo "PASS: provider manifest configures memory, W25Q32, and SD records"
