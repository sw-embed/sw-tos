#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/spi-sdcard"
MEDIA="$OUT_DIR/sdcard.bin"

mkdir -p "$OUT_DIR"
for index in $(seq 0 1023); do
    if [ "$index" -lt 512 ]; then
        value=$((index % 256))
    else
        value=$((255 - (index % 256)))
    fi
    printf "\\$(printf '%03o' "$value")"
done | dd of="$MEDIA" bs=1 count=1024 status=none

"$ROOT_DIR/scripts/catalog-spawn-link.sh" \
    "$ROOT_DIR/tests/spi-sdcard.plsw" spi-sdcard
"$ROOT_DIR/tools/bin/cor24-asm" "$ROOT_DIR/tests/spi-launch-seed.s" \
    -o "$OUT_DIR/seed.lgo"

output=$("$ROOT_DIR/tools/bin/cor24-emu" \
    --lgo "$OUT_DIR/seed.lgo" \
    --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    --spi-device "sdcard@cs=0?file=$MEDIA" \
    --speed 0 -n 3000000 --quiet 2>&1)

expected='FF FE FD FC FB FA F9 F8 F7 F6 F5 F4 F3 F2 F1 F0'
if ! echo "$output" | grep -q "$expected"; then
    echo "FAIL: PL/SW SD-card client did not read sector one" >&2
    echo "$output" >&2
    exit 1
fi
if ! echo "$output" | grep -q 'END'; then
    echo "FAIL: PL/SW SD-card client did not copy through sector byte 511" >&2
    echo "$output" >&2
    exit 1
fi

missing_output=$("$ROOT_DIR/tools/bin/cor24-emu" \
    --lgo "$OUT_DIR/seed.lgo" \
    --load-binary "$OUT_DIR/program.bin@0" --entry 0 \
    --speed 0 -n 3000000 --quiet 2>&1)
if ! echo "$missing_output" | grep -q 'SD ERROR'; then
    echo "FAIL: PL/SW SD-card client did not report a missing card" >&2
    echo "$missing_output" >&2
    exit 1
fi

echo "PASS: PL/SW read all 512 bytes of SD-card sector one"
