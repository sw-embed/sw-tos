#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/hardware-validation"
ACCEPTANCE_REPORT="$ROOT_DIR/build/emulator-acceptance/report.json"

"$ROOT_DIR/scripts/validate-acceptance-report.py" "$ACCEPTANCE_REPORT"

"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-shell.plsw" scheduled-shell
"$ROOT_DIR/scripts/cor24-storage.py" build \
    "$ROOT_DIR/build/catalog-images/swtos-storage.bin"
"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-shell.plsw" scheduled-shell-spi composite-spi
"$ROOT_DIR/tools/bin/cor24-asm" "$ROOT_DIR/tests/spi-launch-seed.s" \
    -o "$ROOT_DIR/build/scheduled-shell-spi/seed.lgo"

mkdir -p "$OUT_DIR"
cp "$ROOT_DIR/build/scheduled-shell/program.bin" \
    "$OUT_DIR/swtos-resident.bin"
cp "$ROOT_DIR/build/scheduled-shell-spi/program.bin" \
    "$OUT_DIR/swtos-spi.bin"
cp "$ROOT_DIR/build/scheduled-shell-spi/seed.lgo" \
    "$OUT_DIR/swtos-spi-seed.lgo"
cp "$ROOT_DIR/build/catalog-images/swtos-storage.bin" \
    "$OUT_DIR/swtos-storage.bin"
cp "$ACCEPTANCE_REPORT" "$OUT_DIR/emulator-acceptance.json"

(
    cd "$OUT_DIR"
    shasum -a 256 swtos-resident.bin swtos-spi.bin \
        swtos-spi-seed.lgo swtos-storage.bin emulator-acceptance.json \
        > SHA256SUMS
)

echo "Hardware validation bundle: $OUT_DIR"
sed -n 'p' "$OUT_DIR/SHA256SUMS"
