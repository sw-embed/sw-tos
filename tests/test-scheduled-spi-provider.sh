#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/scheduled-spi-provider"
MEDIA="$ROOT_DIR/build/catalog-images/swtos-storage.bin"

"$ROOT_DIR/scripts/cor24-storage.py" build "$MEDIA"
"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/catalog-spi.plsw" scheduled-spi-provider
# cor24-emu 0.1.0 attaches SPI devices in its LGO launch path but omits the
# attachment step in binary-only mode. Load a harmless LGO seed, then overlay
# the linked raw image using the emulator's documented combined mode.
"$ROOT_DIR/tools/bin/cor24-asm" "$ROOT_DIR/tests/spi-launch-seed.s" \
    -o "$OUT_DIR/seed.lgo"

output=$("$ROOT_DIR/tools/bin/cor24-emu" \
    --lgo "$OUT_DIR/seed.lgo" --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    --spi-device "w25q32@cs=3?file=$MEDIA" \
    --speed 0 -n 3000000 --quiet 2>/dev/null | sed '/^Entry point:/d')
expected='SPAWN
ESPI CACHE'
if [ "$output" != "$expected" ]; then
    echo "FAIL: expected SPI-backed spawn output:" >&2
    echo "$expected" >&2
    echo "actual:" >&2
    echo "$output" >&2
    exit 1
fi

echo "PASS: scheduled catalog lookup and executable load used W25Q32 storage"
